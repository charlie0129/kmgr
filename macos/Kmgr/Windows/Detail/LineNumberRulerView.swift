import AppKit

/// A vertical ruler that derives line geometry from NSTextView's layout
/// manager, so wrapped logical lines retain one number and very tall lines do
/// not require a parallel text model.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private(set) weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = Self.requiredWidth(forLineCount: Self.lineCount(in: textView.string))

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(textDidChangeNotification),
            name: NSText.didChangeNotification,
            object: textView
        )
        center.addObserver(
            self,
            selector: #selector(visibleBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView is programmatic")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }

        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        layoutManager.ensureLayout(for: textContainer)
        let string = textView.string as NSString
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            draw(
                lineNumber: 1,
                atTextViewY: textView.textContainerOrigin.y,
                textView: textView,
                attributes: lineNumberAttributes
            )
            return
        }

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        let firstGlyph = min(visibleGlyphRange.location, glyphCount - 1)
        let firstCharacter = layoutManager.characterIndexForGlyph(at: firstGlyph)
        var lineNumber = 1
        if firstCharacter > 0 {
            lineNumber += string.substring(to: firstCharacter)
                .reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        }

        let originY = textView.textContainerOrigin.y
        var characterIndex = string.lineRange(
            for: NSRange(location: firstCharacter, length: 0)
        ).location
        let lastVisibleGlyph = max(firstGlyph, min(NSMaxRange(visibleGlyphRange), glyphCount) - 1)
        let visibleCharacterEnd = min(
            string.length,
            layoutManager.characterIndexForGlyph(at: lastVisibleGlyph) + 1
        )

        while characterIndex < visibleCharacterEnd && characterIndex < string.length {
            let lineRange = string.lineRange(
                for: NSRange(location: characterIndex, length: 0)
            )
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            draw(
                lineNumber: lineNumber,
                atTextViewY: originY + fragment.minY,
                fragmentHeight: fragment.height,
                textView: textView,
                attributes: lineNumberAttributes
            )

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= characterIndex || next >= string.length { break }
            characterIndex = next
        }

        if string.hasSuffix("\n"), visibleCharacterEnd == string.length {
            let fragment = layoutManager.extraLineFragmentRect
            if !fragment.isEmpty {
                draw(
                    lineNumber: Self.lineCount(in: textView.string),
                    atTextViewY: originY + fragment.minY,
                    fragmentHeight: fragment.height,
                    textView: textView,
                    attributes: lineNumberAttributes
                )
            }
        }
    }

    private var lineNumberAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        return [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func draw(
        lineNumber: Int,
        atTextViewY textViewY: CGFloat,
        fragmentHeight: CGFloat = NSFont.systemFontSize,
        textView: NSTextView,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = String(lineNumber) as NSString
        let labelHeight = label.size(withAttributes: attributes).height
        guard let rulerY = rulerY(forTextViewY: textViewY) else { return }
        label.draw(
            in: NSRect(
                x: 3,
                y: rulerY + (fragmentHeight - labelHeight) / 2,
                width: ruleThickness - 9,
                height: labelHeight
            ),
            withAttributes: attributes
        )
    }

    @objc private func textDidChangeNotification() { textDidChange() }

    @objc private func visibleBoundsDidChange() { needsDisplay = true }

    /// Converts a document-view line position into ruler coordinates. Kept as
    /// a narrow seam so scrolled clip-view geometry can be smoke-tested without
    /// depending on pixels or private draw state.
    func rulerY(forTextViewY textViewY: CGFloat) -> CGFloat? {
        guard let textView else { return nil }
        return convert(NSPoint(x: 0, y: textViewY), from: textView).y
    }

    func textDidChange() {
        guard let textView else { return }
        let width = Self.requiredWidth(forLineCount: Self.lineCount(in: textView.string))
        if width != ruleThickness { ruleThickness = width }
        needsDisplay = true
    }

    static func lineCount(in text: String) -> Int {
        max(1, text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } })
    }

    static func requiredWidth(forLineCount lineCount: Int) -> CGFloat {
        let digits = max(2, String(max(1, lineCount)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        return ceil(sample.size(withAttributes: [.font: font]).width) + 14
    }
}
