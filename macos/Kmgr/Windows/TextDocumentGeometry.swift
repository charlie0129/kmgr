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
    @MainActor
    struct ViewportState {
        fileprivate var origin: NSPoint
        fileprivate var selection: NSRange

        static func capture(
            textView: NSTextView,
            scrollView: NSScrollView
        ) -> Self {
            Self(
                origin: scrollView.contentView.bounds.origin,
                selection: textView.selectedRange()
            )
        }

        func restore(
            textView: NSTextView,
            scrollView: NSScrollView
        ) {
            let textLength = textView.textStorage?.length ?? 0
            let location = min(max(0, selection.location), textLength)
            let available = max(0, textLength - location)
            textView.setSelectedRange(NSRange(
                location: location,
                length: min(max(0, selection.length), available)
            ))

            let clipView = scrollView.contentView
            let documentBounds = textView.bounds
            let maximumX = max(0, documentBounds.width - clipView.bounds.width)
            let maximumY = max(0, documentBounds.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(
                x: min(max(0, origin.x), maximumX),
                y: min(max(0, origin.y), maximumY)
            ))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

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
    /// for only the current viewport or the final character when Follow is
    /// active. It never calls `ensureLayout(for: textContainer)` and never
    /// reads the whole-container `usedRect` on MainActor.
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

        textView.isHorizontallyResizable = !wrapsToViewport
        textView.autoresizingMask = wrapsToViewport ? [.width] : []
        textContainer.widthTracksTextView = wrapsToViewport
        textContainer.containerSize = NSSize(
            width: wrapsToViewport
                ? max(1, viewportWidth - (inset.width * 2))
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setFrameSize(documentSize)

        let textLength = textView.textStorage?.length ?? 0
        if followingTail, textLength > 0 {
            layoutManager.ensureLayout(forCharacterRange: NSRange(
                location: textLength - 1,
                length: 1
            ))
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
        // Noncontiguous tail layout may publish a coarse TextKit extent. Keep
        // the detached arithmetic frame authoritative until reconciliation.
        textView.setFrameSize(documentSize)
    }
}
