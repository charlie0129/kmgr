import AppKit
import KmgrIPC
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Engine diagnostics")
struct EngineDiagnosticsWindowControllerTests {
    @Test("W toggles line wrapping outside editable fields")
    func wrapShortcut() throws {
        let controller = EngineDiagnosticsWindowController(
            store: EngineDiagnosticsStore()
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let views = engineDiagnosticsDescendants(of: root)
        let logView = try #require(views.compactMap { $0 as? LogViewportView }
            .first { $0.accessibilityLabel() == "Engine diagnostics log" })
        let scrollView = try #require(views.compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "engine-diagnostics-content" })
        let wrap = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Wrap" })
        let search = try #require(views.compactMap { $0 as? NSSearchField }.first)

        #expect(window.makeFirstResponder(logView))
        try sendEngineDiagnosticsKey("w", to: window)
        #expect(wrap.state == .on)
        #expect(logView.wrapsLines)
        #expect(!scrollView.hasHorizontalScroller)

        try sendEngineDiagnosticsKey("w", isARepeat: true, to: window)
        #expect(wrap.state == .on)
        #expect(logView.wrapsLines)

        try sendEngineDiagnosticsKey("w", to: window)
        #expect(wrap.state == .off)
        #expect(!logView.wrapsLines)
        #expect(scrollView.hasHorizontalScroller)

        search.selectText(nil)
        #expect((window.firstResponder as? NSTextView)?.isEditable == true)
        let editableW = try #require(engineDiagnosticsKeyEvent(
            "w",
            window: window
        ))
        #expect(!controller.performEngineDiagnosticsShortcut(editableW))
        #expect(wrap.state == .off)
    }
}
}

@MainActor
private func engineDiagnosticsDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(engineDiagnosticsDescendants(of:))
}

@MainActor
private func sendEngineDiagnosticsKey(
    _ characters: String,
    isARepeat: Bool = false,
    to window: NSWindow
) throws {
    window.sendEvent(try #require(engineDiagnosticsKeyEvent(
        characters,
        isARepeat: isARepeat,
        window: window
    )))
}

@MainActor
private func engineDiagnosticsKeyEvent(
    _ characters: String,
    isARepeat: Bool = false,
    window: NSWindow
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters.lowercased(),
        isARepeat: isARepeat,
        keyCode: 0
    )
}
