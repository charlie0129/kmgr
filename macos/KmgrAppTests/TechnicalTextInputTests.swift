import AppKit
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Technical text input", .serialized)
struct TechnicalTextInputTests {
    @Test("single-line technical fields disable completion and Writing Tools")
    func technicalFieldDefaults() {
        let field = TechnicalTextField()

        #expect(!field.isAutomaticTextCompletionEnabled)
        if #available(macOS 15.2, *) {
            #expect(!field.allowsWritingTools)
        }
    }

    @Test("technical fields configure the shared AppKit field editor")
    func technicalFieldConfiguresFieldEditor() {
        let field = TechnicalTextField()
        let fieldEditor = NSTextView()

        #expect(field.textShouldBeginEditing(fieldEditor))
        expectTechnicalTextInput(fieldEditor)
    }

    @Test("multiline technical editors disable language-oriented services")
    func technicalTextViewConfiguration() {
        let textView = NSTextView()

        textView.configureAsTechnicalTextInput()

        expectTechnicalTextInput(textView)
    }
}
}

@MainActor
private func expectTechnicalTextInput(
    _ textView: NSTextView,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!textView.smartInsertDeleteEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticQuoteSubstitutionEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticDashSubstitutionEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticTextReplacementEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticSpellingCorrectionEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticLinkDetectionEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticDataDetectionEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isAutomaticTextCompletionEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isContinuousSpellCheckingEnabled, sourceLocation: sourceLocation)
    #expect(!textView.isGrammarCheckingEnabled, sourceLocation: sourceLocation)
    #expect(textView.enabledTextCheckingTypes == 0, sourceLocation: sourceLocation)
    #expect(textView.inlinePredictionType == .no, sourceLocation: sourceLocation)
    #expect(textView.mathExpressionCompletionType == .no, sourceLocation: sourceLocation)
    #expect(textView.writingToolsBehavior == .none, sourceLocation: sourceLocation)
}
