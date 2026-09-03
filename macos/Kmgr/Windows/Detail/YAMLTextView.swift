import AppKit

/// Shared keyboard and indentation behavior for YAML documents. Read-only YAML
/// uses `/` as a fast path to AppKit's native find bar; editable YAML keeps `/`
/// as ordinary document input while Command-F continues through the responder
/// chain.
@MainActor
final class YAMLTextView: IndentingTextView {
    var onPlainEditShortcut: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ])
        if !isEditable, modifiers.isEmpty {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "/":
                showFindBar()
                return
            case "e" where onPlainEditShortcut?() == true:
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func showFindBar() {
        let command = NSMenuItem()
        command.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(command)
    }
}
