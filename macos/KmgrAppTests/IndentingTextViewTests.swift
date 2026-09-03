import AppKit
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Document indentation", .serialized)
struct IndentingTextViewTests {
    @Test("detector follows existing tabs and recurring space widths")
    func detectsExistingStyles() {
        #expect(DocumentIndentationDetector.detect(
            in: "root:\n  child:\n    value: true\n" as NSString,
            contentKind: .plain
        ) == .spaces(width: 2))
        #expect(DocumentIndentationDetector.detect(
            in: "root:\n    child:\n        value: true\n" as NSString,
            contentKind: .plain
        ) == .spaces(width: 4))
        #expect(DocumentIndentationDetector.detect(
            in: "script: |\n    first\n      aligned-content\n" as NSString,
            contentKind: .yaml
        ) == .spaces(width: 4))
        #expect(DocumentIndentationDetector.detect(
            in: "root\n\tchild\n\t\tgrandchild\n" as NSString,
            contentKind: .plain
        ) == .tabs(tabWidth: 4))
    }

    @Test("YAML always chooses spaces and structured defaults stay predictable")
    func yamlForcesSpaces() {
        #expect(DocumentIndentationDetector.detect(
            in: "root:\n\tinvalid:\n\t\tvalue: true\n" as NSString,
            contentKind: .yaml
        ) == .spaces(width: 2))
        #expect(DocumentIndentationDetector.detect(
            in: "root:\n\tinvalid: true\n    valid:\n        child: true\n" as NSString,
            contentKind: .yaml
        ) == .spaces(width: 4))
        #expect(DocumentIndentationDetector.detect(
            in: "unindented" as NSString,
            contentKind: .json
        ) == .spaces(width: 2))
        #expect(DocumentIndentationDetector.detect(
            in: "unindented" as NSString,
            contentKind: .plain
        ) == .spaces(width: 4))
    }

    @Test("detection work is bounded by the documented line limit")
    func boundedDetection() {
        let prefix = String(
            repeating: "unindented\n",
            count: DocumentIndentationDetector.maximumLineCount
        )
        let source = prefix + "\tlate-tab-indentation\n"

        #expect(DocumentIndentationDetector.detect(
            in: source as NSString,
            contentKind: .plain
        ) == .spaces(width: 4))
    }

    @Test("Tab advances with spaces while tab-indented text retains literal tabs")
    func insertsDetectedIndentation() {
        let emptyYAML = editableView("", contentKind: .yaml)
        emptyYAML.insertTab(nil)
        #expect(emptyYAML.string == "  ")

        let spaces = editableView("abc", contentKind: .plain)
        spaces.setSelectedRange(NSRange(location: 3, length: 0))
        spaces.insertTab(nil)
        #expect(spaces.string == "abc ")
        #expect(spaces.selectedRange() == NSRange(location: 4, length: 0))

        let tabs = editableView("root\n\tchild\n", contentKind: .plain)
        tabs.setSelectedRange(NSRange(location: (tabs.string as NSString).length, length: 0))
        tabs.insertTab(nil)
        #expect(tabs.string == "root\n\tchild\n\t")

        let yaml = editableView("root:\n\tinvalid\n", contentKind: .yaml)
        yaml.setSelectedRange(NSRange(location: (yaml.string as NSString).length, length: 0))
        yaml.insertTab(nil)
        #expect(yaml.string == "root:\n\tinvalid\n  ")
        yaml.insertText(
            "\tpasted",
            replacementRange: NSRange(location: (yaml.string as NSString).length, length: 0)
        )
        #expect(yaml.string == "root:\n\tinvalid\n  \tpasted")
    }

    @Test("Tab and Shift-Tab change complete selected lines as one undoable edit")
    func blockIndentationAndUndo() throws {
        let original = "one\ntwo\n"
        let view = editableView(original, contentKind: .yaml)
        let scrollView = NSScrollView()
        scrollView.documentView = view
        let window = NSWindow(contentViewController: NSViewController())
        window.contentView = scrollView
        #expect(window.makeFirstResponder(view))
        defer { window.close() }
        view.undoManager?.removeAllActions()

        view.setSelectedRange(NSRange(location: 0, length: 7))
        view.insertTab(nil)
        #expect(view.string == "  one\n  two\n")
        #expect(view.selectedRange() == NSRange(location: 2, length: 9))

        let undoManager = try #require(view.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(view.string == original)

        view.setSelectedRange(NSRange(location: 0, length: 7))
        view.insertTab(nil)
        view.insertBacktab(nil)
        #expect(view.string == original)
        #expect(view.selectedRange() == NSRange(location: 0, length: 7))

        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.insertTab(nil)
        #expect(view.string == "  one\ntwo\n")
    }

    @Test("multiple selected ranges retain their positions after indentation")
    func multipleSelectedRanges() {
        let view = editableView("a\nb\nc", contentKind: .plain)
        view.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 1)),
            NSValue(range: NSRange(location: 4, length: 1)),
        ]

        view.insertTab(nil)

        #expect(view.string == "    a\nb\n    c")
        #expect(view.selectedRanges.map(\.rangeValue) == [
            NSRange(location: 4, length: 1),
            NSRange(location: 12, length: 1),
        ])
    }
}
}

@MainActor
private func editableView(
    _ source: String,
    contentKind: DocumentIndentationContentKind
) -> IndentingTextView {
    let view = IndentingTextView()
    view.isRichText = false
    view.isEditable = true
    view.isSelectable = true
    view.allowsUndo = true
    view.string = source
    view.detectIndentation(for: contentKind)
    return view
}
