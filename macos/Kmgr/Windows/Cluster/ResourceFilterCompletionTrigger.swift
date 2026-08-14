import AppKit

/// Owns the narrow lifecycle for automatically presenting native text
/// completions. The presenter and deferral boundary are injectable so tests do
/// not enter AppKit's modal completion-window tracking loop.
@MainActor
final class ResourceFilterCompletionTrigger {
    typealias DeferredAction = @MainActor () -> Void
    typealias Deferrer = (@escaping DeferredAction) -> Void
    typealias Presenter = @MainActor (NSTextView) -> Void

    private let deferAction: Deferrer
    private let present: Presenter
    private weak var editor: NSTextView?
    private var tokenStart: Int?
    private var generation: UInt64 = 0

    init(
        deferAction: @escaping Deferrer = { action in
            DispatchQueue.main.async { action() }
        },
        present: @escaping Presenter = { editor in editor.complete(nil) }
    ) {
        self.deferAction = deferAction
        self.present = present
    }

    func textDidChange(
        editor candidateEditor: NSTextView?,
        isCurrentEditor: @escaping @MainActor (NSTextView) -> Bool,
        hasCandidates: @escaping @MainActor (NSTextView) -> Bool
    ) {
        guard let candidateEditor,
            let candidateTokenStart = currentTokenStart(in: candidateEditor)
        else {
            reset()
            return
        }
        if editor === candidateEditor, tokenStart == candidateTokenStart {
            return
        }

        reset()
        editor = candidateEditor
        tokenStart = candidateTokenStart
        let expectedGeneration = generation
        deferAction { [weak self, weak candidateEditor] in
            guard let self, let candidateEditor,
                generation == expectedGeneration
            else { return }
            guard editor === candidateEditor,
                isCurrentEditor(candidateEditor),
                currentTokenStart(in: candidateEditor) == candidateTokenStart,
                hasCandidates(candidateEditor)
            else {
                reset()
                return
            }
            present(candidateEditor)
        }
    }

    func reset() {
        generation &+= 1
        editor = nil
        tokenStart = nil
    }

    private func currentTokenStart(in editor: NSTextView) -> Int? {
        let selection = editor.selectedRange()
        let text = editor.string as NSString
        guard selection.location != NSNotFound,
            selection.length == 0,
            selection.location > 0,
            selection.location <= text.length,
            !editor.hasMarkedText()
        else { return nil }

        let whitespace = text.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: NSRange(location: 0, length: selection.location)
        )
        let start = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
        return start < selection.location ? start : nil
    }
}
