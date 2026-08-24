import AppKit

/// A single-line editor for Kubernetes names, numbers, paths, commands, and
/// other values where AppKit's language-oriented text services are unwanted.
@MainActor
final class TechnicalTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 15.2, *) {
            allowsWritingTools = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        let shouldBegin = super.textShouldBeginEditing(textObject)
        if shouldBegin {
            (textObject as? NSTextView)?.configureAsTechnicalTextInput()
        }
        return shouldBegin
    }
}

@MainActor
extension NSTextView {
    /// Disables text checking that can alter or analyze structured input.
    func configureAsTechnicalTextInput() {
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        enabledTextCheckingTypes = 0
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none
    }
}
