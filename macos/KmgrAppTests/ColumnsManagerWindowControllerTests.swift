import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Columns manager windows", .serialized)
struct ColumnsManagerWindowControllerTests {
    @Test("Close button dismisses the columns sheet exactly once")
    func closeButtonDismissesSheet() throws {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var endedSheet: NSWindow?
        var endSheetCount = 0
        let manager = makeColumnsManager(windowDismissal: .init(
            sheetParent: { _ in parent },
            endSheet: { actualParent, sheet in
                #expect(actualParent === parent)
                endedSheet = sheet
                endSheetCount += 1
            },
            close: { _ in Issue.record("A simulated sheet must use endSheet") }
        ))
        var closeCount = 0
        manager.onClose = { closeCount += 1 }

        let root = try #require(manager.window?.contentView)
        let closeButton = try #require(button(titled: "Close", beneath: root))
        closeButton.performClick(nil)

        #expect(endSheetCount == 1)
        #expect(endedSheet === manager.window)
        #expect(closeCount == 0)

        // Both sheet completion and a later close notification can report the
        // lifecycle ending; the controller must notify its owner only once.
        let notification = Notification(
            name: NSWindow.willCloseNotification,
            object: manager.window
        )
        manager.windowWillClose(notification)
        manager.windowWillClose(notification)
        #expect(closeCount == 1)
    }

    @Test("Built-in and metric picker remains separated at its minimum size")
    func nativePickerMinimumSizeLayout() throws {
        let pickerController = NativeColumnPickerWindowController(
            match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            existingColumns: []
        )
        let picker = try #require(pickerController.window)
        #expect(picker.title == "Add Built-in or Metric Column")
        picker.setFrame(
            NSRect(origin: picker.frame.origin, size: picker.minSize),
            display: false
        )
        let root = try #require(picker.contentView)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()

        let help = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("Only extractors supported") })
        let resourceField = try #require(
            view(accessibilityLabel: "Exact Kubernetes resource name", beneath: root)
        )
        let titleField = try #require(
            view(accessibilityLabel: "Exact resource display title", beneath: root)
        )
        let exactButton = try #require(
            button(titled: "Add Exact Resource Disabled", beneath: root)
        )
        let cancelButton = try #require(button(titled: "Cancel", beneath: root))
        let addSelectedButton = try #require(
            button(titled: "Add Disabled", beneath: root)
        )

        let relevantViews = [
            root, help, resourceField, titleField, exactButton, cancelButton,
            addSelectedButton,
        ]
        for candidate in relevantViews {
            #expect(!candidate.hasAmbiguousLayout, "Ambiguous layout for \(candidate)")
        }

        let helpFrame = frame(of: help, in: root)
        let resourceFrame = frame(of: resourceField, in: root)
        let titleFrame = frame(of: titleField, in: root)
        let exactButtonFrame = frame(of: exactButton, in: root)
        let cancelFrame = frame(of: cancelButton, in: root)
        let addSelectedFrame = frame(of: addSelectedButton, in: root)
        let frames = [
            helpFrame, resourceFrame, titleFrame, exactButtonFrame, cancelFrame,
            addSelectedFrame,
        ]

        for candidate in frames {
            #expect(!candidate.isEmpty)
            #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(candidate))
        }

        // AppKit content coordinates run bottom-up: each earlier region is
        // visually above the following region in the picker.
        #expect(helpFrame.minY >= resourceFrame.maxY)
        #expect(resourceFrame.minY >= titleFrame.maxY)
        #expect(titleFrame.minY >= exactButtonFrame.maxY)
        #expect(exactButtonFrame.minY >= cancelFrame.maxY)
        #expect(exactButtonFrame.minY >= addSelectedFrame.maxY)
    }

    @Test("CEL editor uses full-width leading controls and an editable expression responder")
    func celEditorLayoutAndFocus() throws {
        let editor = CELColumnEditorWindowController(
            definition: nil,
            reservedIDs: [],
            previewProvider: NoopColumnPreviewProvider(),
            previewContext: testPreviewContext()
        )
        let panel = try #require(editor.window)
        panel.setFrame(
            NSRect(origin: panel.frame.origin, size: panel.minSize),
            display: false
        )
        let root = try #require(panel.contentView)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()

        let idField = try #require(
            view(accessibilityLabel: "Column ID", beneath: root) as? NSTextField
        )
        let titleField = try #require(
            view(accessibilityLabel: "Column title", beneath: root) as? NSTextField
        )
        let expression = try #require(
            view(accessibilityLabel: "CEL expression", beneath: root) as? NSTextView
        )
        let resultType = try #require(
            view(accessibilityLabel: "Column result type", beneath: root)
        )
        let alignment = try #require(
            view(accessibilityLabel: "Column alignment", beneath: root)
        )
        let missing = try #require(
            view(accessibilityLabel: "Missing value", beneath: root)
        )
        let width = try #require(
            view(accessibilityLabel: "Column width", beneath: root)
        )
        let examplesButton = try #require(
            view(accessibilityLabel: "Show CEL examples", beneath: root) as? NSButton
        )
        let preview = try #require(
            view(accessibilityLabel: "CEL preview value", beneath: root) as? NSTextView
        )
        let selectionTip = try #require(
            view(accessibilityLabel: "CEL preview selection tip", beneath: root)
                as? NSTextField
        )

        for control in [idField, titleField, resultType, alignment, missing, width] {
            let controlFrame = frame(of: control, in: root)
            #expect(!controlFrame.isEmpty)
            #expect(controlFrame.width >= 200)
            #expect(!control.hasAmbiguousLayout)
        }
        let expressionFrame = frame(of: expression, in: root)
        #expect(!expressionFrame.isEmpty)
        #expect(expressionFrame.width >= 430)
        #expect(!expression.hasAmbiguousLayout)
        let labels = descendants(of: root).compactMap { $0 as? NSTextField }.filter {
            ["ID", "Title", "Expression", "Result type", "Alignment", "Missing value", "Width"]
                .contains($0.stringValue)
        }
        #expect(labels.count == 7)
        #expect(labels.allSatisfy { $0.alignment == .left })

        #expect(expression.isEditable)
        #expect(expression.isSelectable)
        #expect(examplesButton.bezelStyle == .helpButton)
        #expect(examplesButton.action != nil)
        #expect(selectionTip.stringValue.contains("Select one"))
        #expect(selectionTip.stringValue.contains("safe sample object"))
        #expect(!selectionTip.isHidden)
        #expect(!preview.isEditable)
        #expect(preview.isSelectable)
        #expect(frame(of: preview, in: root).height <= 160)
        #expect(titleField.nextKeyView === expression)
        #expect(expression.nextKeyView === resultType)
        #expect(panel.makeFirstResponder(expression))
        expression.insertText(
            "object.metadata.name",
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(expression.string == "object.metadata.name")
    }

    @Test("discovered disabled resources merge without overriding configured identity")
    func discoveredColumnsMerge() {
        let configured = ColumnDefinition(
            id: "my-gpu",
            title: "Production GPU",
            source: .metric,
            value: "resource:nvidia.com/gpu",
            type: .resourceUsage,
            enabled: false
        )
        let duplicateGPU = ColumnDefinition(
            id: "resource:nvidia.com/gpu",
            title: "GPU",
            source: .metric,
            value: "resource:nvidia.com/gpu",
            type: .resourceUsage
        )
        let hugePages = ColumnDefinition(
            id: "resource:hugepages-2Mi",
            title: "Huge Pages (2Mi)",
            source: .metric,
            value: "resource:hugepages-2Mi",
            type: .resourceUsage,
            enabled: false
        )

        let merged = ColumnsManagerWindowController.mergingDiscoveredColumns(
            [duplicateGPU, hugePages],
            into: [configured]
        )
        #expect(merged == [configured, hugePages])
        #expect(!merged[1].isEnabled)
    }
}
}

private struct NoopColumnPreviewProvider: ColumnPreviewProviding {
    func previewColumn(_ request: ColumnPreviewRequest) async throws -> ColumnPreviewResult {
        Issue.record("Column preview was not expected in this test")
        throw CancellationError()
    }
}

@MainActor
private func makeColumnsManager(
    windowDismissal: ColumnsManagerWindowController.WindowDismissal = .appKit
) -> ColumnsManagerWindowController {
    ColumnsManagerWindowController(
        resourceTitle: "Pods",
        match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
        defaultColumns: [],
        previewProvider: NoopColumnPreviewProvider(),
        previewContext: testPreviewContext(),
        configurationPath: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("columns.yaml")
            .path,
        windowDismissal: windowDismissal
    )
}

private func testPreviewContext() -> ColumnPreviewContext {
    ColumnPreviewContext(
        sessionID: "test-session",
        resource: DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true
        ),
        namespaceScope: NamespaceSelection()
    )
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants(of:))
}

@MainActor
private func button(titled title: String, beneath root: NSView) -> NSButton? {
    descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == title }
}

@MainActor
private func view(accessibilityLabel label: String, beneath root: NSView) -> NSView? {
    descendants(of: root).first { $0.accessibilityLabel() == label }
}

@MainActor
private func frame(of view: NSView, in root: NSView) -> NSRect {
    view.convert(view.bounds, to: root)
}
