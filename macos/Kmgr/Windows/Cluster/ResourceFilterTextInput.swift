import AppKit

/// Marks the resource-query field as the client for the dedicated field
/// editor below. AppKit otherwise consumes Tab inside its completion
/// controller before the control delegate can accept an unselected row.
@MainActor
final class ResourceFilterSearchField: NSSearchField {
    var acceptFirstCompletion: ((NSTextView) -> Bool)?
}

/// Intercepts Tab before AppKit's native completion controller. Every other
/// command, including Return, follows the normal field-editor delegate path.
@MainActor
final class ResourceFilterFieldEditor: NSTextView {
    weak var completionField: ResourceFilterSearchField?

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
        if selector == #selector(NSResponder.insertTab(_:)),
            completionField?.acceptFirstCompletion?(self) == true
        {
            return
        }
        super.doCommand(by: selector)
    }
}
