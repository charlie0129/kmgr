import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Shared key-value diff confirmation", .serialized)
struct KeyValueDiffConfirmationWindowControllerTests {
    @Test("text values produce contextual unified hunks and preserve newline state")
    func textPresentation() throws {
        let before = "one\ntwo\nthree\nold value\nfive\nsix\nseven\neight"
        let after = "one\ntwo\nthree\nnew value\nfive\nsix\nseven\neight\n"
        let presentation = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "settings.ini",
            afterKey: "settings.ini",
            beforeKind: .text,
            beforeValue: Data(before.utf8),
            afterKind: .text,
            afterValue: Data(after.utf8),
            sensitive: false
        ))

        #expect(presentation.format == .text)
        #expect(presentation.metadataText == "Text · 44 bytes → Text · 45 bytes")
        #expect(presentation.text.contains("--- saved value"))
        #expect(presentation.text.contains("+++ edited value"))
        #expect(presentation.text.contains("-old value"))
        #expect(presentation.text.contains("+new value"))
        #expect(presentation.text.contains("@@ -"))
        #expect(presentation.text.contains("\\ No newline at end of value"))
        #expect(!presentation.previewTruncated)

        let createdEmpty = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: nil,
            afterKey: "recreated",
            beforeKind: nil,
            beforeValue: nil,
            afterKind: .text,
            afterValue: Data(),
            sensitive: false
        ))
        #expect(createdEmpty.metadataText == "Absent → Text · 0 bytes")
        #expect(createdEmpty.text.contains("-<absent>"))
        #expect(createdEmpty.text.contains("+(empty)"))
    }

    @Test("oversized single-line values show the actual changed region")
    func focusedLongLinePresentation() {
        let prefix = String(repeating: "p", count: 12_000)
        let suffix = String(repeating: "s", count: 12_000)
        let presentation = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "large.json",
            afterKey: "large.json",
            beforeKind: .text,
            beforeValue: Data((prefix + "OLD-MARKER" + suffix).utf8),
            afterKind: .text,
            afterValue: Data((prefix + "NEW-MARKER" + suffix).utf8),
            sensitive: false
        ))

        #expect(presentation.previewTruncated)
        #expect(presentation.text.contains("OLD-MARKER"))
        #expect(presentation.text.contains("NEW-MARKER"))
        #expect(presentation.text.contains("bounded changed text region"))
        #expect(presentation.text.utf8.count
            < KeyValueDiffPresentation.maximumRenderedUTF8ByteCount)

        let fragmentedBefore = (0..<3_000).map { "old-\($0)" }.joined(separator: "\n")
        let fragmentedAfter = (0..<3_000).map { "new-\($0)" }.joined(separator: "\n")
        let fragmented = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "fragmented.txt",
            afterKey: "fragmented.txt",
            beforeKind: .text,
            beforeValue: Data(fragmentedBefore.utf8),
            afterKind: .text,
            afterValue: Data(fragmentedAfter.utf8),
            sensitive: false
        ))
        #expect(fragmented.previewTruncated)
        #expect(fragmented.text.contains("bounded changed text region"))
        #expect(fragmented.text.utf8.count
            < KeyValueDiffPresentation.maximumRenderedUTF8ByteCount)

        let newlineHeavy = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "lines.txt",
            afterKey: "lines.txt",
            beforeKind: .text,
            beforeValue: Data(String(repeating: "a\n", count: 20_000).utf8),
            afterKind: .text,
            afterValue: Data(String(repeating: "b\n", count: 20_000).utf8),
            sensitive: false
        ))
        #expect(newlineHeavy.previewTruncated)
        #expect(newlineHeavy.text.contains("bounded changed text region"))
        #expect(newlineHeavy.text.utf8.count
            < KeyValueDiffPresentation.maximumRenderedUTF8ByteCount)

        let combining = "a" + String(repeating: "\u{301}", count: 30_000)
        let combiningHeavy = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "unicode.txt",
            afterKey: "unicode.txt",
            beforeKind: .text,
            beforeValue: Data((combining + "OLD").utf8),
            afterKind: .text,
            afterValue: Data((combining + "NEW").utf8),
            sensitive: false
        ))
        #expect(combiningHeavy.previewTruncated)
        #expect(combiningHeavy.text.contains("OLD"))
        #expect(combiningHeavy.text.contains("NEW"))
        #expect(combiningHeavy.text.utf8.count
            < KeyValueDiffPresentation.maximumRenderedUTF8ByteCount)
    }

    @Test("binary comparison centers its bounded output on changed bytes")
    func focusedBinaryPresentation() {
        var before = Data(repeating: 0x41, count: 1_024)
        var after = before
        before[800] = 0x10
        after[800] = 0xFF
        let presentation = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "archive.bin",
            afterKey: "archive.bin",
            beforeKind: .binary,
            beforeValue: before,
            afterKind: .binary,
            afterValue: after,
            sensitive: false
        ))

        #expect(presentation.format == .binary)
        #expect(presentation.text.contains("@@ changed byte ranges @@"))
        #expect(presentation.text.contains("00000320"))
        #expect(presentation.text.contains("FF"))
        #expect(presentation.text.contains("^^"))
        #expect(!presentation.previewTruncated)

        let manyBefore = Data(repeating: 0x00, count: 1_024)
        let manyAfter = Data(repeating: 0xFF, count: 1_024)
        let bounded = KeyValueDiffPresentation(input: KeyValueDiffInput(
            beforeKey: "many.bin",
            afterKey: "many.bin",
            beforeKind: .binary,
            beforeValue: manyBefore,
            afterKind: .binary,
            afterValue: manyAfter,
            sensitive: false
        ))
        #expect(bounded.previewTruncated)
        #expect(bounded.text.contains("additional changed byte rows omitted"))
    }

    @Test("master-detail Secret review presents every change kind and clears values")
    func secretWindowPresentation() async throws {
        let inputs = [
            KeyValueDiffInput(
                beforeKey: "token",
                afterKey: "token",
                beforeKind: .text,
                beforeValue: Data("old-secret\nline-two".utf8),
                afterKind: .text,
                afterValue: Data("new-secret\nline-two".utf8),
                sensitive: true
            ),
            KeyValueDiffInput(
                beforeKey: nil,
                afterKey: "added",
                beforeKind: nil,
                beforeValue: nil,
                afterKind: .text,
                afterValue: Data("new".utf8),
                sensitive: true
            ),
            KeyValueDiffInput(
                beforeKey: "old-name",
                afterKey: "new-name",
                beforeKind: .binary,
                beforeValue: Data([0x01]),
                afterKind: .binary,
                afterValue: Data([0x01]),
                sensitive: true
            ),
            KeyValueDiffInput(
                beforeKey: "deleted",
                afterKey: nil,
                beforeKind: .text,
                beforeValue: Data("gone".utf8),
                afterKind: nil,
                afterValue: nil,
                sensitive: true
            ),
        ]
        let controller = KeyValueDiffConfirmationWindowController(
            editorTitle: "Secret Data",
            targetDetails: "Context reference: /tmp/kubeconfig#dev · UID uid-1",
            inputs: inputs
        )
        defer { controller.close() }

        let panel = try #require(controller.window)
        let root = try #require(panel.contentView)
        let views = keyValueDiffDescendants(of: root)
        let changesTable = try #require(views.compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "key-value-diff-changes" })
        let textView = try #require(views.compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "key-value-diff-text" })
        let secretNotice = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "key-value-diff-sensitive-notice" })
        let copy = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "key-value-diff-copy" })
        let search = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "key-value-diff-search" })
        let save = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "key-value-diff-save" })
        let keepEditing = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "key-value-diff-keep-editing" })

        try await waitForKeyValueDiff { textView.string.contains("new-secret") }
        #expect(panel.title == "Review Secret Data Changes")
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.isRestorable == false)
        #expect(panel.minSize == NSSize(width: 760, height: 480))
        #expect(changesTable.numberOfRows == 4)
        let changeValues = (0..<changesTable.numberOfRows).compactMap { row in
            (changesTable.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NSTableCellView)?.textField?.stringValue
        }
        #expect(changeValues == ["Modified", "Added", "Renamed", "Deleted"])
        #expect(!secretNotice.isHidden)
        #expect(secretNotice.stringValue.contains("not Kubernetes base64 text"))
        #expect(textView.string.contains("old-secret"))
        #expect(textView.string.contains("new-secret"))
        #expect(!textView.string.contains(Data("old-secret".utf8).base64EncodedString()))
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.usesFindBar)
        expectPreciseScrollingLayout(textView)
        let whitespaceLayout = try #require(textView.layoutManager as? WhitespaceLayoutManager)
        #expect(whitespaceLayout.whitespaceVisualizationEnabled)
        let whitespaceRanges = try #require(
            whitespaceLayout.whitespaceVisualizationCharacterRanges
        )
        let diffText = textView.string as NSString
        let removalLine = diffText.range(of: "-old-secret")
        let removalNewline = diffText.range(
            of: "\n",
            options: [],
            range: NSRange(
                location: NSMaxRange(removalLine),
                length: diffText.length - NSMaxRange(removalLine)
            )
        )
        #expect(whitespaceRanges.contains {
            $0.location == removalLine.location + 1
                && $0.length == removalLine.length - 1
        })
        #expect(whitespaceRanges.allSatisfy {
            !NSLocationInRange(removalLine.location, $0)
        })
        #expect(whitespaceRanges.allSatisfy {
            removalNewline.location == NSNotFound || !NSLocationInRange(
                removalNewline.location,
                $0
            )
        })
        #expect(textView.isVerticallyResizable)
        #expect(textView.isHorizontallyResizable)
        #expect(textView.autoresizingMask.contains(.height))
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(textView.textContainer?.containerSize.width
            == CGFloat.greatestFiniteMagnitude)
        #expect(search.title == "Search")
        #expect(save.keyEquivalent == "\r")
        #expect(keepEditing.keyEquivalent == "\u{1b}")

        let text = textView.string as NSString
        let removalRange = text.range(of: "-old-secret")
        let additionRange = text.range(of: "+new-secret")
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
        #expect(copied?.hasPrefix("Modified: token\nText · 19 bytes → Text · 19 bytes") == true)
        #expect(copied?.contains("Unified Value Diff") == true)
        #expect(copied?.hasSuffix(textView.string) == true)

        controller.discardTransientPresentation()
        #expect(textView.string.isEmpty)
    }

    @Test("review is a parent sheet and never enters an application-modal loop")
    func sheetPresentation() async throws {
        let input = KeyValueDiffInput(
            beforeKey: "token",
            afterKey: "token",
            beforeKind: .text,
            beforeValue: Data("old-secret".utf8),
            afterKind: .text,
            afterValue: Data("new-secret".utf8),
            sensitive: true
        )
        let controller = KeyValueDiffConfirmationWindowController(
            editorTitle: "Secret Data",
            targetDetails: "Context reference: /tmp/kubeconfig#dev · UID uid-1",
            inputs: [input]
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
        let views = keyValueDiffDescendants(of: root)
        let textView = try #require(views.compactMap { $0 as? NSTextView }
            .first { $0.identifier?.rawValue == "key-value-diff-text" })
        let save = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "key-value-diff-save" })
        let reviewTask = Task { @MainActor in
            await controller.runSheet(for: parent)
        }
        defer {
            reviewTask.cancel()
            if parent.attachedSheet === panel { parent.endSheet(panel) }
            panel.orderOut(nil)
            parent.orderOut(nil)
        }

        try await waitForDiffSheet(parent: parent, sheet: panel)
        #expect(panel.sheetParent === parent)
        #expect(NSApp.modalWindow == nil)

        save.performClick(nil)
        let choice = await reviewTask.value
        if case .save = choice {} else {
            Issue.record("expected Save to finish the sheet with .save")
        }
        #expect(parent.attachedSheet == nil)
        #expect(textView.string.isEmpty)
    }
}
}

@MainActor
private func keyValueDiffDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(keyValueDiffDescendants(of:))
}

private func waitForKeyValueDiff(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("selected key-value diff was not rendered")
    throw CancellationError()
}

@MainActor
private func waitForDiffSheet(parent: NSWindow, sheet: NSWindow) async throws {
    for _ in 0..<100 {
        if parent.attachedSheet === sheet { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("diff review sheet was not attached to its parent")
    throw CancellationError()
}
