import AppKit

/// Establishes and maintains the document geometry that `NSScrollView` does
/// not infer for a programmatically-created `NSTextView`. A nonzero string is
/// not sufficient: the document frame must cover the viewport and the laid
/// out text must fit inside that frame.
@MainActor
enum TextDocumentGeometry {
    /// Uses TextKit 1 for scrollable documents before their content is
    /// installed. On macOS 15, TextKit 2 can stall AppKit's concurrent
    /// precise-scrolling path used by trackpads even when scrollbar and mouse
    /// wheel scrolling remain smooth.
    static func prepareForPreciseScrolling(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else {
            preconditionFailure("AppKit did not create a text layout manager")
        }
        layoutManager.allowsNonContiguousLayout = true
    }

    /// Installs the editor-style whitespace renderer used by structured text
    /// editors. This changes presentation only: the document string,
    /// selections, copy/paste, and undo history remain unchanged.
    ///
    /// Keep this on the TextKit 1 layout manager used by the app's large
    /// editors. The renderer invalidates presentation when its state changes,
    /// so callers do not need to insert marker characters or maintain a second
    /// rendered string.
    static func configureWhitespaceVisualization(
        _ textView: NSTextView,
        enabled: Bool
    ) {
        guard let existingLayoutManager = textView.layoutManager else {
            preconditionFailure("AppKit did not create a text layout manager")
        }

        let layoutManager: WhitespaceLayoutManager
        if let existingLayoutManager = existingLayoutManager as? WhitespaceLayoutManager {
            layoutManager = existingLayoutManager
        } else {
            let replacement = WhitespaceLayoutManager()
            replacement.delegate = existingLayoutManager.delegate
            replacement.usesDefaultHyphenation = existingLayoutManager.usesDefaultHyphenation
            replacement.usesFontLeading = existingLayoutManager.usesFontLeading
            replacement.allowsNonContiguousLayout = existingLayoutManager.allowsNonContiguousLayout
            replacement.limitsLayoutForSuspiciousContents =
                existingLayoutManager.limitsLayoutForSuspiciousContents
            replacement.backgroundLayoutEnabled = existingLayoutManager.backgroundLayoutEnabled
            replacement.defaultAttachmentScaling = existingLayoutManager.defaultAttachmentScaling
            replacement.typesetterBehavior = existingLayoutManager.typesetterBehavior
            replacement.typesetter = existingLayoutManager.typesetter
            guard let textContainer = textView.textContainer else {
                preconditionFailure("AppKit did not create a text container")
            }
            textContainer.replaceLayoutManager(replacement)
            layoutManager = replacement
        }

        // The custom renderer replaces AppKit's heavy built-in glyphs.
        layoutManager.showsInvisibleCharacters = false
        layoutManager.showsControlCharacters = false
        layoutManager.whitespaceVisualizationEnabled = enabled
    }

    static func configure(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        wrapsToViewport: Bool,
        fallbackSize: NSSize = NSSize(width: 640, height: 320)
    ) {
        prepareForPreciseScrolling(textView)
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
}
