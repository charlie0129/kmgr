import AppKit

/// Detached, content-free measurements for sizing a streaming log document.
/// Width units deliberately overestimate non-ASCII glyphs using their UTF-8
/// width; the values contain no log text and are safe to retain on MainActor.
struct LogTextLayoutMetrics: Hashable, Sendable {
    static let empty = LogTextLayoutMetrics(
        logicalLineCount: 1,
        maximumLineWidthUnits: 0,
        totalLineWidthUnits: 0,
        measuredWrappingColumnCapacity: 1,
        measuredVisualLineCount: 1
    )

    var logicalLineCount: Int
    var maximumLineWidthUnits: Int
    var totalLineWidthUnits: Int
    var measuredWrappingColumnCapacity: Int
    var measuredVisualLineCount: Int

    init(chunks: [String], wrappingColumnCapacity: Int) {
        let capacity = max(1, wrappingColumnCapacity)
        var lines = 0
        var maximumWidth = 0
        var totalWidth = 0
        var visualLines = 0
        var currentWidth = 0
        var previousWasCarriageReturn = false

        func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
            let addition = lhs.addingReportingOverflow(rhs)
            return addition.overflow ? Int.max : addition.partialValue
        }

        func visualLineCount(for width: Int) -> Int {
            guard width > 0 else { return 1 }
            return 1 + ((width - 1) / capacity)
        }

        func widthUnits(for scalar: Unicode.Scalar) -> Int {
            if scalar.value == 0x09 {
                // Match the conventional eight-column tab stops closely
                // enough for conservative monospaced document sizing.
                return 8 - (currentWidth % 8)
            }
            switch scalar.value {
            case ...0x7f: return 1
            case ...0x7ff: return 2
            case ...0xffff: return 3
            default: return 4
            }
        }

        func finishLine() {
            lines = addingWithoutOverflow(lines, 1)
            maximumWidth = max(maximumWidth, currentWidth)
            totalWidth = addingWithoutOverflow(totalWidth, currentWidth)
            visualLines = addingWithoutOverflow(
                visualLines,
                visualLineCount(for: currentWidth)
            )
            currentWidth = 0
        }

        for chunk in chunks {
            for scalar in chunk.unicodeScalars {
                // Treat CRLF as one line boundary even when its two scalars
                // arrive in separate renderer chunks.
                if scalar.value == 0x0a, previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    continue
                }
                previousWasCarriageReturn = false
                if CharacterSet.newlines.contains(scalar) {
                    finishLine()
                    previousWasCarriageReturn = scalar.value == 0x0d
                } else {
                    currentWidth = addingWithoutOverflow(
                        currentWidth,
                        widthUnits(for: scalar)
                    )
                }
            }
        }
        // NSTextView exposes an extra line fragment after a trailing newline,
        // and an empty document still has one editable/display line.
        finishLine()

        self.init(
            logicalLineCount: lines,
            maximumLineWidthUnits: maximumWidth,
            totalLineWidthUnits: totalWidth,
            measuredWrappingColumnCapacity: capacity,
            measuredVisualLineCount: visualLines
        )
    }

    func estimatedVisualLineCount(wrappingColumnCapacity: Int) -> Int {
        let capacity = max(1, wrappingColumnCapacity)
        guard capacity != measuredWrappingColumnCapacity else {
            return measuredVisualLineCount
        }

        // A resize gets an immediate bounded estimate. LogWindowController
        // follows it with a debounced detached exact measurement at the new
        // capacity, so this path never scans the log on MainActor.
        let aggregateLowerBound = max(
            logicalLineCount,
            totalLineWidthUnits == 0
                ? logicalLineCount
                : 1 + ((totalLineWidthUnits - 1) / capacity)
        )
        let longestLineLowerBound = max(
            logicalLineCount,
            logicalLineCount - 1 + max(
                1,
                maximumLineWidthUnits == 0
                    ? 1
                    : 1 + ((maximumLineWidthUnits - 1) / capacity)
            )
        )
        let measuredOverflow = max(0, measuredVisualLineCount - logicalLineCount)
        let scaledOverflow: Int
        if measuredOverflow == 0 {
            scaledOverflow = 0
        } else {
            let product = measuredOverflow.multipliedReportingOverflow(
                by: measuredWrappingColumnCapacity
            )
            let scaled = product.overflow ? Int.max : product.partialValue
            scaledOverflow = scaled == Int.max
                ? Int.max
                : (scaled + capacity - 1) / capacity
        }
        let scaledEstimate = scaledOverflow == Int.max
            ? Int.max
            : logicalLineCount.addingReportingOverflow(scaledOverflow).overflow
                ? Int.max
                : logicalLineCount + scaledOverflow
        return max(aggregateLowerBound, longestLineLowerBound, scaledEstimate)
    }

    private init(
        logicalLineCount: Int,
        maximumLineWidthUnits: Int,
        totalLineWidthUnits: Int,
        measuredWrappingColumnCapacity: Int,
        measuredVisualLineCount: Int
    ) {
        self.logicalLineCount = logicalLineCount
        self.maximumLineWidthUnits = maximumLineWidthUnits
        self.totalLineWidthUnits = totalLineWidthUnits
        self.measuredWrappingColumnCapacity = measuredWrappingColumnCapacity
        self.measuredVisualLineCount = measuredVisualLineCount
    }
}

/// Establishes and maintains the document geometry that `NSScrollView` does
/// not infer for a programmatically-created `NSTextView`. A nonzero string is
/// not sufficient: the document frame must cover the viewport and the laid
/// out text must fit inside that frame.
@MainActor
enum TextDocumentGeometry {
    static func configure(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        wrapsToViewport: Bool,
        fallbackSize: NSSize = NSSize(width: 640, height: 320)
    ) {
        let viewport = scrollView.contentSize
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(1, max(viewport.width, fallbackSize.width)),
                height: max(1, max(viewport.height, fallbackSize.height))
            )
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapsToViewport
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = wrapsToViewport
        update(textView, in: scrollView, wrapsToViewport: wrapsToViewport)
    }

    /// Synchronizes the document frame after text replacement or viewport
    /// resize. For unwrapped documents, the layout manager determines both
    /// axes. Wrapped documents first receive the viewport width, then their
    /// height is measured using that width.
    static func update(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        wrapsToViewport: Bool
    ) {
        guard let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager
        else { return }

        let viewport = scrollView.contentSize
        // Detached tab documents and a window's just-installed content view
        // can report a zero viewport until their first Auto Layout pass. Keep
        // the configured fallback geometry until a real viewport is known.
        let viewportWidth = max(
            1,
            viewport.width > 1 ? viewport.width : textView.frame.width
        )
        let viewportHeight = max(
            1,
            viewport.height > 1 ? viewport.height : textView.frame.height
        )
        let inset = textView.textContainerInset

        textView.isHorizontallyResizable = !wrapsToViewport
        textContainer.widthTracksTextView = wrapsToViewport
        if wrapsToViewport {
            let currentHeight = max(1, max(viewportHeight, textView.frame.height))
            textView.setFrameSize(NSSize(width: viewportWidth, height: currentHeight))
            textContainer.containerSize = NSSize(
                width: max(1, viewportWidth - (inset.width * 2)),
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let contentWidth = ceil(used.maxX + (inset.width * 2))
        let contentHeight = ceil(used.maxY + (inset.height * 2))
        textView.setFrameSize(NSSize(
            width: wrapsToViewport
                ? viewportWidth
                : max(1, max(viewportWidth, contentWidth)),
            height: max(1, max(viewportHeight, contentHeight))
        ))
    }

    /// Configures the lazy TextKit contract used only by the bounded streaming
    /// log surface. YAML and Data editors retain `update`'s exact layout path.
    static func configureStreamingLog(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        fallbackSize: NSSize = NSSize(width: 640, height: 320)
    ) {
        configure(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            fallbackSize: fallbackSize
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        updateStreamingLog(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            metrics: .empty,
            followingTail: false
        )
    }

    static func streamingLogWrappingColumnCapacity(
        _ textView: NSTextView,
        in scrollView: NSScrollView
    ) -> Int {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = max(
            1,
            ("M" as NSString).size(withAttributes: [.font: font]).width
        )
        let inset = textView.textContainerInset.width * 2
        let padding = (textView.textContainer?.lineFragmentPadding ?? 0) * 2
        let available = max(1, scrollView.contentSize.width - inset - padding)
        return max(1, Int(floor(available / advance)))
    }

    /// Sizes a log from detached arithmetic measurements, then asks TextKit
    /// for only the current viewport or a bounded tail suffix. It never calls
    /// `ensureLayout(for: textContainer)` or reads the whole-container
    /// `usedRect` on MainActor.
    static func updateStreamingLog(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        wrapsToViewport: Bool,
        metrics: LogTextLayoutMetrics,
        followingTail: Bool
    ) {
        guard let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager
        else { return }
        layoutManager.allowsNonContiguousLayout = true

        let viewport = scrollView.contentSize
        let viewportWidth = max(
            1,
            viewport.width > 1 ? viewport.width : textView.frame.width
        )
        let viewportHeight = max(
            1,
            viewport.height > 1 ? viewport.height : textView.frame.height
        )
        let inset = textView.textContainerInset
        let padding = textContainer.lineFragmentPadding * 2
        let font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = max(
            1,
            ("M" as NSString).size(withAttributes: [.font: font]).width
        )
        let lineHeight = max(1, layoutManager.defaultLineHeight(for: font))
        let columnCapacity = streamingLogWrappingColumnCapacity(textView, in: scrollView)
        let lineCount = wrapsToViewport
            ? metrics.estimatedVisualLineCount(wrappingColumnCapacity: columnCapacity)
            : metrics.logicalLineCount
        let measuredHeight = ceil(
            CGFloat(lineCount) * lineHeight + (inset.height * 2)
        )
        let measuredWidth = ceil(
            CGFloat(metrics.maximumLineWidthUnits) * advance
                + (inset.width * 2) + padding
        )
        let documentSize = NSSize(
            width: wrapsToViewport
                ? viewportWidth
                : max(viewportWidth, measuredWidth),
            height: max(viewportHeight, measuredHeight)
        )

        // Detached metrics own the complete streaming-log document frame.
        // NSTextView's automatic resize path derives a second, partial frame
        // from noncontiguous TextKit layout and can later replace this one as
        // the real tail is resolved.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textContainer.widthTracksTextView = wrapsToViewport
        textContainer.containerSize = NSSize(
            width: wrapsToViewport
                ? max(1, viewportWidth - (inset.width * 2))
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setFrameSize(documentSize)

        if followingTail {
            anchorStreamingLogTail(
                textView,
                layoutManager: layoutManager,
                documentHeight: documentSize.height,
                viewportHeight: viewportHeight,
                lineHeight: lineHeight
            )
        } else {
            let containerOrigin = textView.textContainerOrigin
            var visible = scrollView.contentView.bounds.offsetBy(
                dx: -containerOrigin.x,
                dy: -containerOrigin.y
            )
            // One viewport of look-ahead keeps ordinary scrolling smooth while
            // retaining a request size independent of total log length.
            visible = visible.insetBy(dx: 0, dy: -viewportHeight)
            visible.origin.x = max(0, visible.origin.x)
            visible.origin.y = max(0, visible.origin.y)
            layoutManager.ensureLayout(forBoundingRect: visible, in: textContainer)
        }
        // Noncontiguous layout can publish a coarse TextKit extent. Keep the
        // detached arithmetic frame authoritative until reconciliation.
        textView.setFrameSize(documentSize)
    }

    private static func anchorStreamingLogTail(
        _ textView: NSTextView,
        layoutManager: NSLayoutManager,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        lineHeight: CGFloat
    ) {
        guard let textStorage = textView.textStorage, textStorage.length > 0 else {
            return
        }

        // Keep enough complete logical lines to fill the viewport, but cap the
        // suffix so a user-configured oversized line cannot make tail following
        // proportional to the full document.
        let requiredLines = max(2, Int(ceil(viewportHeight / lineHeight)) + 2)
        let maximumTailUTF16Length = 512 << 10
        let string = textStorage.string as NSString
        var characterStart = textStorage.length
        for _ in 0..<requiredLines {
            guard characterStart > 0 else { break }
            var lineStart = 0
            string.getLineStart(
                &lineStart,
                end: nil,
                contentsEnd: nil,
                for: NSRange(location: characterStart - 1, length: 0)
            )
            if textStorage.length - lineStart > maximumTailUTF16Length {
                let cappedStart = max(
                    0,
                    textStorage.length - maximumTailUTF16Length
                )
                characterStart = string.rangeOfComposedCharacterSequence(
                    at: cappedStart
                ).location
                break
            }
            characterStart = lineStart
        }

        let characterRange = NSRange(
            location: characterStart,
            length: textStorage.length - characterStart
        )
        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        struct LineFragment {
            var rect: NSRect
            var usedRect: NSRect
            var glyphRange: NSRange
        }
        var fragments: [LineFragment] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            rect, usedRect, _, glyphRange, _ in
            fragments.append(LineFragment(
                rect: rect,
                usedRect: usedRect,
                glyphRange: glyphRange
            ))
        }
        guard !fragments.isEmpty else { return }

        var currentBottom = fragments.dropFirst().reduce(fragments[0].rect.maxY) {
            max($0, $1.rect.maxY)
        }
        if !layoutManager.extraLineFragmentRect.isEmpty {
            currentBottom = max(
                currentBottom,
                layoutManager.extraLineFragmentRect.maxY
            )
        }
        let desiredBottom = max(
            0,
            documentHeight - (textView.textContainerInset.height * 2)
        )
        let offset = desiredBottom - currentBottom
        guard abs(offset) > 0.5 else { return }

        let firstFragment = fragments[0]
        layoutManager.setLineFragmentRect(
            firstFragment.rect.offsetBy(dx: 0, dy: offset),
            forGlyphRange: firstFragment.glyphRange,
            usedRect: firstFragment.usedRect.offsetBy(dx: 0, dy: offset)
        )
        // TextKit preserves fragment adjacency, so moving the first fragment
        // shifts the complete laid-out suffix and its trailing extra line.
    }

    /// Follows a streaming log's vertical tail using the authoritative frame
    /// computed above. The bounded suffix has already been anchored to this
    /// edge, so arithmetic scrolling remains constant work and preserves the
    /// user's horizontal position.
    static func scrollStreamingLogToTail(
        _ textView: NSTextView,
        in scrollView: NSScrollView
    ) {
        let clipView = scrollView.contentView
        let maximumX = max(0, textView.bounds.width - clipView.bounds.width)
        let maximumY = max(0, textView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(
            x: min(max(0, clipView.bounds.origin.x), maximumX),
            y: maximumY
        ))
        scrollView.reflectScrolledClipView(clipView)
    }
}
