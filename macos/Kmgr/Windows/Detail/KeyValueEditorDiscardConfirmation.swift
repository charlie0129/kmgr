import AppKit

/// Shared close/back safeguard for editors whose key changes are staged until
/// one batch save. Keeping the safe action as the default prevents Return from
/// accidentally discarding a transaction.
@MainActor
enum KeyValueEditorDiscardConfirmation {
    static func shouldDiscard(
        editorTitle: String,
        targetDetails: String
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard unsaved \(editorTitle) changes?"
        alert.informativeText = "\(targetDetails)\n\nAdded, edited, renamed, and deleted keys will not be saved."
        alert.addButton(withTitle: "Keep Editing")
        let discardButton = alert.addButton(withTitle: "Discard Changes")
        discardButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
