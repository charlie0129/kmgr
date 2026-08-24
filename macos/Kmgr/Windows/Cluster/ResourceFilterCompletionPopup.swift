import AppKit

@MainActor
private final class ResourceFilterCompletionTableView: NSTableView {
    var onClickRow: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        guard clickedRow >= 0 else { return }
        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        onClickRow?(clickedRow)
    }
}

/// A small in-window completion surface for the resource query.
///
/// The search field remains the first responder while this view is visible.
/// That keeps the query text authoritative and lets the resource field editor
/// own commands, while the popup owns only candidate display and selection.
@MainActor
final class ResourceFilterCompletionPopup: NSView, NSTableViewDataSource,
    NSTableViewDelegate
{
    static let maximumVisibleRows = 8
    static let rowHeight: CGFloat = 26

    var onAccept: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = ResourceFilterCompletionTableView()
    private var heightConstraint: NSLayoutConstraint!
    private var values: [String] = []

    var isPresented: Bool { !isHidden && !values.isEmpty }
    var visibleValues: [String] { values }
    var selectedIndex: Int? {
        let row = tableView.selectedRow
        return values.indices.contains(row) ? row : nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func present(values: [String]) {
        self.values = values
        reloadSelection()
        isHidden = self.values.isEmpty
        let visibleRowCount = min(self.values.count, Self.maximumVisibleRows)
        heightConstraint.constant = CGFloat(visibleRowCount) * Self.rowHeight + 2
        needsLayout = true
    }

    func dismiss() {
        values.removeAll(keepingCapacity: true)
        tableView.deselectAll(nil)
        isHidden = true
        heightConstraint.constant = 0
    }

    @discardableResult
    func moveSelection(by delta: Int) -> Bool {
        guard !values.isEmpty, delta != 0 else { return false }
        let current = selectedIndex
        let next: Int
        if let current {
            next = min(max(current + delta, 0), values.count - 1)
        } else {
            next = delta > 0 ? 0 : values.count - 1
        }
        select(row: next)
        return true
    }

    @discardableResult
    func acceptSelectedOrFirst() -> Bool {
        guard !values.isEmpty else { return false }
        onAccept?(selectedIndex ?? 0)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { values.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard values.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("resource-filter-completion-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = values[row]
        cell.textField?.toolTip = values[row]
        return cell
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        updateColors()
        setAccessibilityRole(.list)
        setAccessibilityLabel("Resource query completions")

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityLabel("Resource query completion options")
        tableView.focusRingType = .none
        tableView.onClickRow = { [weak self] row in
            self?.onAccept?(row)
        }

        let column = NSTableColumn(identifier: .init("completion"))
        column.resizingMask = [.autoresizingMask]
        tableView.addTableColumn(column)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = textField
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func reloadSelection() {
        tableView.reloadData()
        tableView.deselectAll(nil)
    }

    private func select(row: Int) {
        guard values.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}
