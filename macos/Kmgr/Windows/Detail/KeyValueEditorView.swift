import AppKit
import KmgrCore

/// Reusable AppKit composition for map-like editors.
///
/// The view owns the common search/table/value layout, table persistence,
/// keyboard routing, text geometry, and structured-text highlighting. Domain
/// controllers continue to own rows, validation, sensitive-value authority,
/// drafts, and persistence.
@MainActor
final class KeyValueEditorView: NSView {
    struct Column {
        var id: String
        var title: String
        var width: CGFloat
        var minimumWidth: CGFloat
    }

    struct Configuration {
        var identifierPrefix: String
        var splitAutosaveName: String
        var tableAccessibilityLabel: String
        var valueAccessibilityLabel: String
        var tableSurface: TableSurfaceID
        var columns: [Column]
        var preferredLeadingFraction: CGFloat = 0.45
        var paneMinimums = KeyValueEditorSplitView.PaneMinimums(
            leading: 260,
            trailing: 340
        )
    }

    let splitView = KeyValueEditorSplitView()
    let searchField = NSSearchField()
    let resultLabel = NSTextField(labelWithString: "")
    let tableView = KeyValueEditorTableView()
    let valueTextView = NSTextView()
    let valueScrollView = NSScrollView()
    let selectedKeyLabel = NSTextField(labelWithString: "No key selected")
    let selectedKeyDetailsLabel = NSTextField(labelWithString: "")

    private let leadingActions = NSStackView()
    private let leadingAccessory = NSStackView()
    private let headerActions = NSStackView()
    private let trailingActions = NSStackView()
    private var tableLayoutBinding: TableLayoutBinding?
    private var syntaxHighlighter: SyntaxHighlighter?
    private var syntaxKey: String?

    init(
        configuration: Configuration,
        tableLayoutStore: TableLayoutStore
    ) {
        super.init(frame: .zero)
        configure(
            configuration: configuration,
            tableLayoutStore: tableLayoutStore
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func layout() {
        super.layout()
        splitView.establishPositionIfNeeded()
        updateDocumentGeometry()
    }

    func setLeadingActionViews(_ views: [NSView]) {
        replaceArrangedSubviews(of: leadingActions, with: views)
        leadingActions.isHidden = views.isEmpty
    }

    func setLeadingAccessoryViews(_ views: [NSView]) {
        replaceArrangedSubviews(of: leadingAccessory, with: views)
        leadingAccessory.isHidden = views.isEmpty
    }

    func setHeaderActionViews(_ views: [NSView]) {
        replaceArrangedSubviews(of: headerActions, with: views)
        headerActions.isHidden = views.isEmpty
    }

    func setTrailingActionViews(_ views: [NSView]) {
        replaceArrangedSubviews(of: trailingActions, with: views)
        trailingActions.isHidden = views.isEmpty
    }

    func updateSyntaxHighlighting(
        key: String?,
        isTextValue: Bool
    ) {
        guard let syntaxHighlighter else { return }
        let source: NSString = valueTextView.textStorage?.mutableString
            ?? (valueTextView.string as NSString)
        let retainedMode = syntaxKey == key ? syntaxHighlighter.mode : .none
        let mode = KeyValueSyntaxHighlightingModeDetector.mode(
            forKey: key ?? "",
            isTextValue: isTextValue,
            source: source,
            retaining: retainedMode
        )
        syntaxHighlighter.setMode(mode)
        syntaxHighlighter.setWhitespaceVisualization(isTextValue)
        syntaxKey = isTextValue ? key : nil
    }

    func clearSyntaxHighlighting() {
        syntaxHighlighter?.setMode(.none)
        syntaxHighlighter?.setWhitespaceVisualization(false)
        syntaxKey = nil
    }

    func applySearchHighlight(to field: NSTextField?, query: String) {
        guard let field, !query.isEmpty, !field.stringValue.isEmpty else { return }
        let value = field.stringValue as NSString
        let attributed = NSMutableAttributedString(string: field.stringValue)
        var remaining = NSRange(location: 0, length: value.length)
        while remaining.length > 0 {
            let match = value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: remaining
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35),
                range: match
            )
            let next = match.location + match.length
            remaining = NSRange(location: next, length: value.length - next)
        }
        field.attributedStringValue = attributed
    }

    func updateDocumentGeometry() {
        TextDocumentGeometry.update(
            valueTextView,
            in: valueScrollView,
            wrapsToViewport: true
        )
    }

    private func configure(
        configuration: Configuration,
        tableLayoutStore: TableLayoutStore
    ) {
        identifier = .init("\(configuration.identifierPrefix)-view")
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.identifier = .init("\(configuration.identifierPrefix)-split")
        splitView.autosaveName = configuration.splitAutosaveName
        splitView.preferredLeadingFraction = configuration.preferredLeadingFraction
        splitView.paneMinimumsProvider = { configuration.paneMinimums }
        splitView.onDidResize = { [weak self] in self?.updateDocumentGeometry() }

        for specification in configuration.columns {
            let column = NSTableColumn(identifier: .init(specification.id))
            column.title = specification.title
            column.width = specification.width
            column.minWidth = specification.minimumWidth
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel(configuration.tableAccessibilityLabel)
        tableLayoutBinding = TableLayoutBinding(
            tableView: tableView,
            surface: configuration.tableSurface,
            store: tableLayoutStore
        )

        let tableScroll = NSScrollView()
        tableScroll.identifier = .init("\(configuration.identifierPrefix)-keys-scroll")
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true

        searchField.placeholderString = "Search keys and values"
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search keys and values")
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resultLabel.alignment = .right
        resultLabel.lineBreakMode = .byClipping
        resultLabel.setContentHuggingPriority(.required, for: .horizontal)
        let searchRow = NSStackView(views: [searchField, resultLabel])
        configureHorizontalStack(searchRow, spacing: 8)

        configureHorizontalStack(leadingActions, spacing: 8)
        configureHorizontalStack(leadingAccessory, spacing: 8)
        leadingActions.isHidden = true
        leadingAccessory.isHidden = true

        let keyPane = NSView()
        keyPane.identifier = .init("\(configuration.identifierPrefix)-keys-pane")
        for child in [searchRow, leadingActions, leadingAccessory, tableScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            keyPane.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchRow.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor, constant: 8),
            searchRow.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor, constant: -8),
            searchRow.topAnchor.constraint(equalTo: keyPane.topAnchor, constant: 7),
            leadingActions.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor, constant: 8),
            leadingActions.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor, constant: -8),
            leadingActions.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            leadingAccessory.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor, constant: 8),
            leadingAccessory.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor, constant: -8),
            leadingAccessory.topAnchor.constraint(equalTo: leadingActions.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: leadingAccessory.bottomAnchor, constant: 6),
            tableScroll.bottomAnchor.constraint(equalTo: keyPane.bottomAnchor),
        ])

        valueTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueTextView.isRichText = false
        valueTextView.isEditable = false
        valueTextView.isSelectable = true
        valueTextView.allowsUndo = true
        valueTextView.isAutomaticQuoteSubstitutionEnabled = false
        valueTextView.isAutomaticDashSubstitutionEnabled = false
        valueTextView.isAutomaticTextReplacementEnabled = false
        valueTextView.isAutomaticSpellingCorrectionEnabled = false
        valueTextView.isContinuousSpellCheckingEnabled = false
        valueTextView.setAccessibilityLabel(configuration.valueAccessibilityLabel)
        valueScrollView.documentView = valueTextView
        valueScrollView.setAccessibilityLabel(configuration.valueAccessibilityLabel)
        valueScrollView.hasVerticalScroller = true
        valueScrollView.hasHorizontalScroller = false
        valueScrollView.identifier = .init("\(configuration.identifierPrefix)-value-scroll")
        TextDocumentGeometry.configure(
            valueTextView,
            in: valueScrollView,
            wrapsToViewport: true
        )
        syntaxHighlighter = SyntaxHighlighter(
            textView: valueTextView,
            scrollView: valueScrollView,
            mode: .none,
            whitespaceVisualizationEnabled: false
        )

        selectedKeyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        selectedKeyLabel.lineBreakMode = .byTruncatingMiddle
        selectedKeyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectedKeyLabel.setAccessibilityLabel("Selected key")
        selectedKeyDetailsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        selectedKeyDetailsLabel.textColor = .secondaryLabelColor
        selectedKeyDetailsLabel.lineBreakMode = .byTruncatingTail
        selectedKeyDetailsLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        selectedKeyDetailsLabel.setAccessibilityLabel("Selected key details")
        let selectedHeader = NSStackView(views: [
            selectedKeyLabel, selectedKeyDetailsLabel,
        ])
        selectedHeader.orientation = .vertical
        selectedHeader.alignment = .leading
        selectedHeader.spacing = 1
        configureHorizontalStack(headerActions, spacing: 8)
        headerActions.isHidden = true
        let header = NSStackView(views: [selectedHeader, NSView(), headerActions])
        configureHorizontalStack(header, spacing: 8)

        configureHorizontalStack(trailingActions, spacing: 8)
        trailingActions.isHidden = true
        let valuePane = NSView()
        valuePane.identifier = .init("\(configuration.identifierPrefix)-editor-pane")
        for child in [header, trailingActions, valueScrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            valuePane.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: valuePane.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: valuePane.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: valuePane.topAnchor, constant: 7),
            trailingActions.leadingAnchor.constraint(equalTo: valuePane.leadingAnchor, constant: 8),
            trailingActions.trailingAnchor.constraint(equalTo: valuePane.trailingAnchor, constant: -8),
            trailingActions.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            valueScrollView.leadingAnchor.constraint(equalTo: valuePane.leadingAnchor),
            valueScrollView.trailingAnchor.constraint(equalTo: valuePane.trailingAnchor),
            valueScrollView.topAnchor.constraint(equalTo: trailingActions.bottomAnchor, constant: 5),
            valueScrollView.bottomAnchor.constraint(equalTo: valuePane.bottomAnchor),
        ])

        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        splitView.addArrangedSubview(keyPane)
        splitView.addArrangedSubview(valuePane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureHorizontalStack(
        _ stack: NSStackView,
        spacing: CGFloat
    ) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
    }

    private func replaceArrangedSubviews(
        of stack: NSStackView,
        with views: [NSView]
    ) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views { stack.addArrangedSubview(view) }
    }
}
