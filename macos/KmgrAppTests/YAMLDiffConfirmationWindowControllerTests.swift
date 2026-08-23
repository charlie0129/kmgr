import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("YAML diff confirmation", .serialized)
struct YAMLDiffConfirmationWindowControllerTests {
    @Test("presentation preserves contextual diff roles and appends decoded Secret values")
    func transientPresentation() throws {
        let binaryBefore = Data((0..<300).map { UInt8($0 % 251) })
        var binaryAfter = binaryBefore
        binaryAfter[17] = 0xFF
        let prepared = PreparedYAMLEdit(
            normalizedYAMLUTF8: Data("kind: Secret\n".utf8),
            currentResourceVersion: "rv-2",
            diff: [
                SemanticDiffEntry(
                    path: "metadata.labels.team",
                    beforeSummary: "\"platform\"",
                    afterSummary: "\"runtime\""
                ),
                SemanticDiffEntry(
                    path: "data.token",
                    beforeSummary: "<redacted>",
                    afterSummary: "<redacted>",
                    beforeDecodedSecretValue: SensitiveBytes(Data("old-token\nline-2".utf8)),
                    afterDecodedSecretValue: SensitiveBytes(Data("new-token\nline-2".utf8))
                ),
                SemanticDiffEntry(
                    path: "data.archive",
                    beforeSummary: "<redacted>",
                    afterSummary: "<redacted>",
                    beforeDecodedSecretValue: SensitiveBytes(binaryBefore),
                    afterDecodedSecretValue: SensitiveBytes(binaryAfter)
                ),
            ],
            unifiedDiffUTF8: Data("""
                --- server
                +++ edited
                @@ -3,4 +3,4 @@
                 metadata:
                -  team: platform
                +  team: runtime
                """.utf8),
            unifiedDiffTruncated: true
        )

        let presentation = YAMLDiffPresentation(prepared: prepared)

        #expect(presentation.changedPaths.count == 3)
        #expect(presentation.changedPaths.map(\.path) == [
            "metadata.labels.team", "data.token", "data.archive",
        ])
        #expect(presentation.unifiedDiffTruncated)
        #expect(presentation.text.contains("@@ -3,4 +3,4 @@"))
        #expect(presentation.text.contains("Decoded Secret value changes"))
        #expect(presentation.text.contains("old-token\nline-2"))
        #expect(presentation.text.contains("new-token\nline-2"))
        #expect(presentation.text.contains("decoded binary, 300 bytes"))
        #expect(presentation.text.contains("additional bytes not shown"))

        let removal = try #require(presentation.lines.first { $0.text == "-  team: platform" })
        let addition = try #require(presentation.lines.first { $0.text == "+  team: runtime" })
        let hunk = try #require(presentation.lines.first { $0.text.hasPrefix("@@") })
        if case .removal = removal.role {} else {
            Issue.record("expected a removal line role")
        }
        if case .addition = addition.role {} else {
            Issue.record("expected an addition line role")
        }
        if case .hunkHeader = hunk.role {} else {
            Issue.record("expected a hunk-header line role")
        }
    }

    @Test("decoded UTF-8 rendering is byte-safe and line-bounded")
    func boundedDecodedText() {
        let newlineHeavy = Data(String(repeating: "\n", count: 20_000).utf8)
        let unicodeHeavy = Data(("x" + String(repeating: "🙂", count: 5_000)).utf8)
        let prepared = PreparedYAMLEdit(
            normalizedYAMLUTF8: Data(),
            currentResourceVersion: "rv",
            diff: [
                SemanticDiffEntry(
                    path: "data.lines",
                    beforeSummary: "<redacted>",
                    afterSummary: "<absent>",
                    beforeDecodedSecretValue: SensitiveBytes(newlineHeavy)
                ),
                SemanticDiffEntry(
                    path: "data.unicode",
                    beforeSummary: "<redacted>",
                    afterSummary: "<absent>",
                    beforeDecodedSecretValue: SensitiveBytes(unicodeHeavy)
                ),
            ]
        )

        let presentation = YAMLDiffPresentation(prepared: prepared)
        let renderedText = presentation.text

        #expect(renderedText.contains("bytes omitted"))
        #expect(renderedText.contains("decoded display limit: 16 KiB"))
        #expect(renderedText.contains("�") == false)
        #expect(presentation.lines.count
            <= YAMLDiffPresentation.maximumDecodedSecretDisplayLineCount + 8)
    }

    @Test("resizable window exposes changed paths, colored selectable diff, Copy All, and find")
    func windowPresentation() throws {
        let prepared = PreparedYAMLEdit(
            normalizedYAMLUTF8: Data("kind: ConfigMap\n".utf8),
            currentResourceVersion: "rv-3",
            diff: [SemanticDiffEntry(
                path: "data.mode",
                beforeSummary: "\"safe\"",
                afterSummary: "\"fast\"",
                severity: .warning
            )],
            unifiedDiffUTF8: Data("""
                --- server
                +++ edited
                @@ -1,3 +1,3 @@
                -mode: safe
                +mode: fast
                """.utf8)
        )
        let controller = YAMLDiffConfirmationWindowController(
            targetDetails: "Context reference: /tmp/kubeconfig#dev · UID uid-1",
            prepared: prepared
        )
        defer { controller.close() }

        let panel = try #require(controller.window)
        let root = try #require(panel.contentView)
        let views = yamlDiffDescendants(of: root)
        let textView = try #require(views.compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "yaml-diff-text" })
        let table = try #require(views.compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "yaml-diff-paths" })
        let copy = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-diff-copy-all" })
        let search = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-diff-search" })
        let apply = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-diff-apply" })
        let keepEditing = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-diff-keep-editing" })

        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.isRestorable == false)
        #expect(panel.minSize.width == 680)
        #expect(table.numberOfRows == 1)
        #expect(textView.isEditable == false)
        #expect(textView.isSelectable)
        #expect(textView.isRichText)
        #expect(textView.usesFindBar)
        expectPreciseScrollingLayout(textView)
        let whitespaceLayout = try #require(textView.layoutManager as? WhitespaceLayoutManager)
        #expect(whitespaceLayout.whitespaceVisualizationEnabled)
        let whitespaceRanges = try #require(
            whitespaceLayout.whitespaceVisualizationCharacterRanges
        )
        let diffText = textView.string as NSString
        let removalLine = diffText.range(of: "-mode: safe")
        let fileHeader = diffText.range(of: "--- server")
        let firstNewline = diffText.range(of: "\n")
        #expect(whitespaceRanges.contains {
            $0.location == removalLine.location + 1
                && $0.length == removalLine.length - 1
        })
        #expect(whitespaceRanges.allSatisfy {
            !NSLocationInRange(fileHeader.location, $0)
                && !NSLocationInRange(firstNewline.location, $0)
        })
        #expect(textView.isVerticallyResizable)
        #expect(textView.isHorizontallyResizable)
        #expect(textView.autoresizingMask.contains(.height))
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(textView.textContainer?.containerSize.width
            == CGFloat.greatestFiniteMagnitude)
        #expect(search.title == "Search")
        #expect(apply.keyEquivalent == "\r")
        #expect(keepEditing.keyEquivalent == "\u{1b}")

        let text = textView.string as NSString
        let removalRange = text.range(of: "-mode: safe")
        let additionRange = text.range(of: "+mode: fast")
        #expect(removalRange.location != NSNotFound)
        #expect(additionRange.location != NSNotFound)
        let removalColor = textView.textStorage?.attribute(
            .foregroundColor, at: removalRange.location, effectiveRange: nil
        ) as? NSColor
        let additionColor = textView.textStorage?.attribute(
            .foregroundColor, at: additionRange.location, effectiveRange: nil
        ) as? NSColor
        #expect(removalColor == .systemRed)
        #expect(additionColor == .systemGreen)

        let pasteboard = NSPasteboard.general
        defer { pasteboard.clearContents() }
        copy.performClick(nil)
        let copied = pasteboard.string(forType: .string)
        #expect(copied?.hasPrefix("Changed Paths\nPath\tBefore\tAfter") == true)
        #expect(copied?.contains("data.mode\t\"safe\"\t\"fast\"") == true)
        #expect(copied?.hasSuffix(textView.string) == true)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(textView.string.isEmpty)
    }

    @Test("review is a parent sheet and never enters an application-modal loop")
    func sheetPresentation() async throws {
        let prepared = PreparedYAMLEdit(
            normalizedYAMLUTF8: Data("kind: Secret\n".utf8),
            currentResourceVersion: "rv-3",
            diff: [SemanticDiffEntry(
                path: "data.token",
                beforeSummary: "<redacted>",
                afterSummary: "<redacted>",
                beforeDecodedSecretValue: SensitiveBytes(Data("old-secret".utf8)),
                afterDecodedSecretValue: SensitiveBytes(Data("new-secret".utf8))
            )],
            unifiedDiffUTF8: Data("""
                --- server
                +++ edited
                @@ -1 +1 @@
                -kind: ConfigMap
                +kind: Secret
                """.utf8)
        )
        let controller = YAMLDiffConfirmationWindowController(
            targetDetails: "Context reference: /tmp/kubeconfig#dev · UID uid-1",
            prepared: prepared
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.makeKeyAndOrderFront(nil)
        let panel = try #require(controller.window)
        let root = try #require(panel.contentView)
        let views = yamlDiffDescendants(of: root)
        let textView = try #require(views.compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "yaml-diff-text" })
        let apply = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-diff-apply" })
        let reviewTask = Task { @MainActor in
            await controller.runSheet(for: parent)
        }
        defer {
            reviewTask.cancel()
            if parent.attachedSheet === panel { parent.endSheet(panel) }
            panel.orderOut(nil)
            parent.orderOut(nil)
        }

        try await waitForYAMLDiffSheet(parent: parent, sheet: panel)
        #expect(panel.sheetParent === parent)
        #expect(NSApp.modalWindow == nil)

        apply.performClick(nil)
        let choice = await reviewTask.value
        if case .apply = choice {} else {
            Issue.record("expected Apply to finish the sheet with .apply")
        }
        #expect(parent.attachedSheet == nil)
        #expect(textView.string.isEmpty)
    }
}
}

@MainActor
private func yamlDiffDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(yamlDiffDescendants)
}

@MainActor
private func waitForYAMLDiffSheet(parent: NSWindow, sheet: NSWindow) async throws {
    for _ in 0..<100 {
        if parent.attachedSheet === sheet { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("YAML diff review sheet was not attached to its parent")
    throw CancellationError()
}
