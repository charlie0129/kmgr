import AppKit

/// Field editor used only by the resource query. It gives the custom popup a
/// stable command interception point while leaving all other text fields on
/// AppKit's shared editor.
@MainActor
final class ResourceFilterFieldEditor: NSTextView {
    var commandHandler: ((Selector) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isFieldEditor = true
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isFieldEditor = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func doCommand(by selector: Selector) {
        if commandHandler?(selector) == true { return }
        super.doCommand(by: selector)
    }
}
