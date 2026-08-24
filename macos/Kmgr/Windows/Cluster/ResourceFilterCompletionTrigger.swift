import AppKit

/// Schedules a completion presentation after a query token changes.
///
/// The trigger is deliberately small and stateful only for presentation
/// lifetime. Query text and completion candidates remain owned by the search
/// field and `ResourceFilterCompletionCatalog`; no hidden filter state is
/// introduced here.
@MainActor
final class ResourceFilterCompletionTrigger {
    typealias DeferredAction = @MainActor () -> Void
    typealias Deferrer = (@escaping DeferredAction) -> Void
    typealias Presenter = @MainActor (NSTextView) -> Void

    private let deferAction: Deferrer
    private var present: Presenter
    private weak var editor: NSTextView?
    private var tokenState: TokenState?
    private var generation: UInt64 = 0

    private struct TokenState: Equatable {
        var start: Int
        var text: String
    }

    init(
        deferAction: @escaping Deferrer = { action in
            DispatchQueue.main.async { action() }
        },
        present: @escaping Presenter = { _ in }
    ) {
        self.deferAction = deferAction
        self.present = present
    }

    func setPresenter(_ present: @escaping Presenter) {
        self.present = present
    }

    func textDidChange(
        editor candidateEditor: NSTextView?,
        isCurrentEditor: @escaping @MainActor (NSTextView) -> Bool,
        hasCandidates: @escaping @MainActor (NSTextView) -> Bool
    ) {
        guard let candidateEditor,
            let candidateTokenState = currentTokenState(in: candidateEditor)
        else {
            reset()
            return
        }
        if editor === candidateEditor, tokenState == candidateTokenState {
            return
        }

        reset()
        editor = candidateEditor
        tokenState = candidateTokenState
        let expectedGeneration = generation
        deferAction { [weak self, weak candidateEditor] in
            guard let self, let candidateEditor,
                self.generation == expectedGeneration,
                self.editor === candidateEditor,
                self.tokenState == candidateTokenState
            else {
                return
            }
            guard isCurrentEditor(candidateEditor) else {
                self.reset()
                return
            }
            guard self.currentTokenState(in: candidateEditor) == candidateTokenState
            else {
                self.reset()
                return
            }
            guard hasCandidates(candidateEditor) else {
                self.reset()
                return
            }
            self.present(candidateEditor)
        }
    }

    func reset() {
        generation &+= 1
        editor = nil
        tokenState = nil
    }

    private func currentTokenState(in editor: NSTextView) -> TokenState? {
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
        guard start < selection.location else { return nil }
        return TokenState(
            start: start,
            text: text.substring(with: NSRange(
                location: start,
                length: selection.location - start
            ))
        )
    }
}
