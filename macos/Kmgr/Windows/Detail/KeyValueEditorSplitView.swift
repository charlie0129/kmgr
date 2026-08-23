import AppKit

/// Shared master-detail split behavior for the Data and metadata key/value
/// editors. It owns pane constraints, autosaved-position validation, and the
/// double-click reset without coupling either surface's data semantics.
@MainActor
final class KeyValueEditorSplitView: NSSplitView,
    @preconcurrency NSSplitViewDelegate
{
    struct PaneMinimums {
        var leading: CGFloat
        var trailing: CGFloat
    }

    var preferredLeadingFraction: CGFloat = 0.45
    var paneMinimumsProvider: (() -> PaneMinimums)?
    var onDidResize: (() -> Void)?

    private var establishedInitialPosition = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let location = convert(event.locationInWindow, from: nil)
            if dividerIndex(at: location) != nil {
                resetDividerPosition()
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        guard arrangedSubviews.count > 1 else { return nil }
        for index in 0..<(arrangedSubviews.count - 1) {
            let preceding = arrangedSubviews[index].frame
            let divider: NSRect
            if isVertical {
                divider = NSRect(
                    x: preceding.maxX - 3,
                    y: bounds.minY,
                    width: dividerThickness + 6,
                    height: bounds.height
                )
            } else {
                divider = NSRect(
                    x: bounds.minX,
                    y: preceding.maxY - 3,
                    width: bounds.width,
                    height: dividerThickness + 6
                )
            }
            if divider.contains(point) { return index }
        }
        return nil
    }

    func establishPositionIfNeeded() {
        guard !establishedInitialPosition,
            arrangedSubviews.count == 2,
            bounds.width > dividerThickness
        else { return }
        establishedInitialPosition = true
        let minimums = effectivePaneMinimums()
        let leadingWidth = arrangedSubviews[0].frame.width
        let trailingWidth = arrangedSubviews[1].frame.width
        if leadingWidth < minimums.leading || trailingWidth < minimums.trailing {
            resetDividerPosition()
        }
    }

    func resetDividerPosition() {
        guard arrangedSubviews.count == 2 else { return }
        establishedInitialPosition = true
        let available = max(0, bounds.width - dividerThickness)
        guard available > 0 else { return }
        let minimums = effectivePaneMinimums()
        let preferred = available * min(max(preferredLeadingFraction, 0), 1)
        let position = min(
            max(preferred, minimums.leading),
            max(minimums.leading, available - minimums.trailing)
        )
        setPosition(position, ofDividerAt: 0)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self, dividerIndex == 0 else {
            return proposedMinimumPosition
        }
        return max(
            proposedMinimumPosition,
            bounds.minX + effectivePaneMinimums().leading
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self, dividerIndex == 0 else {
            return proposedMaximumPosition
        }
        return min(
            proposedMaximumPosition,
            bounds.maxX - effectivePaneMinimums().trailing
        )
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(
        _ splitView: NSSplitView,
        shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt dividerIndex: Int
    ) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        onDidResize?()
        establishPositionIfNeeded()
    }

    private func effectivePaneMinimums() -> PaneMinimums {
        var minimums = paneMinimumsProvider?()
            ?? PaneMinimums(leading: 260, trailing: 300)
        minimums.leading = max(0, minimums.leading)
        minimums.trailing = max(0, minimums.trailing)
        let available = max(0, bounds.width - dividerThickness)
        let combined = minimums.leading + minimums.trailing
        if combined > available, combined > 0 {
            let scale = available / combined
            minimums.leading *= scale
            minimums.trailing *= scale
        }
        return minimums
    }
}

/// Keyboard plumbing shared by key lists. Controllers provide only the
/// context-specific actions (for example Secret reveal or sheet dismissal).
@MainActor
final class KeyValueEditorTableView: NSTableView {
    var onFocusSearch: (() -> Void)?
    var onActivateValue: (() -> Void)?
    var onBack: (() -> Void)?
    var onUnmodifiedKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ])
        let characters = event.charactersIgnoringModifiers?.lowercased()
        switch (characters, event.keyCode) {
        case ("/", _) where modifiers.isEmpty:
            onFocusSearch?()
        case ("f", _) where modifiers == .command:
            onFocusSearch?()
        case (_, 36) where modifiers.isEmpty && onActivateValue != nil:
            onActivateValue?()
        case (_, 53) where modifiers.isEmpty && onBack != nil:
            onBack?()
        case (let value?, _) where modifiers.isEmpty:
            guard onUnmodifiedKey?(value) != true else { return }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }
}
