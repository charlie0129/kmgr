import AppKit

/// A view-based table that copies the complete value of the cell most
/// recently clicked. Cell labels remain passive AppKit labels, so clicking
/// never enters a field editor or paints a text selection over the row.
///
/// Callers may provide a value resolver when the rendered label is shortened
/// or otherwise deliberately differs from the value that should be copied.
@MainActor
class CapturedCellTableView: NSTableView, NSMenuItemValidation {
    var cellValueProvider: ((Int, Int) -> String?)?
    private(set) var capturedCellValue: String?
    private weak var copyMenuItem: NSMenuItem?

    var canCopyCapturedCell: Bool { capturedCellValue != nil }

    func addCopyCellMenuItem(
        to menu: NSMenu,
        title: String = "Copy Cell"
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        copyMenuItem = item
        updateCopyMenuItem()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        captureCellValue(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        captureCellValue(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }

    /// Edit > Copy and Command-C use the immutable value captured at the last
    /// cell click, independent of cell reuse, scrolling, and table selection.
    @objc func copy(_ sender: Any?) {
        guard let capturedCellValue else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(capturedCellValue, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return canCopyCapturedCell
        }
        return true
    }

    /// Captures the logical value for a point without changing row selection.
    /// The resolver is preferred so truncated or protected presentations can
    /// choose the exact value that is safe and useful to copy.
    func captureCellValue(at point: NSPoint) {
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0 else {
            capturedCellValue = nil
            updateCopyMenuItem()
            return
        }
        if let cellValueProvider {
            capturedCellValue = cellValueProvider(row, column)
            updateCopyMenuItem()
            return
        }
        guard let cell = view(
            atColumn: column,
            row: row,
            makeIfNecessary: true
        ) as? NSTableCellView else {
            capturedCellValue = nil
            updateCopyMenuItem()
            return
        }
        capturedCellValue = cell.textField?.stringValue
        updateCopyMenuItem()
    }

    private func updateCopyMenuItem() {
        copyMenuItem?.isEnabled = canCopyCapturedCell
    }
}
