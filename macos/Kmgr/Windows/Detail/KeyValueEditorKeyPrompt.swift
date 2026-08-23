import AppKit

/// Shared key-name prompt used by map editors. Domain controllers still own
/// key validation because Kubernetes Data keys and metadata qualified names
/// have different rules.
@MainActor
enum KeyValueEditorKeyPrompt {
    struct Request {
        enum Action {
            case add
            case rename
        }

        var action: Action
        var singularTitle: String
        var currentValue: String?
        var informativeText: String
    }

    static func run(_ request: Request) -> String? {
        let actionTitle = request.action == .add ? "Add" : "Rename"
        let alert = NSAlert()
        alert.messageText = "\(actionTitle) \(request.singularTitle)"
        alert.informativeText = request.informativeText
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 340, height: 24)
        )
        field.stringValue = request.currentValue ?? ""
        field.placeholderString = "Key name"
        alert.accessoryView = field
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
