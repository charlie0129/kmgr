import AppKit

enum DiffTextLineRole: Hashable, Sendable {
    case context
    case fileHeader
    case hunkHeader
    case addition
    case removal
    case sectionHeader
    case notice
}

enum DiffTextWhitespaceScope: Hashable, Sendable {
    case none
    /// Render markers across the complete line content. The line separator
    /// remains excluded.
    case content
    /// Render markers in the source content after the unified-diff prefix.
    /// The line separator itself is intentionally excluded.
    case contentAfterDiffPrefix
}

struct DiffTextLine: Hashable, Sendable {
    var text: String
    var role: DiffTextLineRole
    var whitespaceScope: DiffTextWhitespaceScope = .none
}

/// Suspends a diff review's async save flow while AppKit presents a regular
/// parent-window sheet. `NSApplication.runModal(for:)` uses a nested event
/// loop that starves AppKit's concurrent precise-scrolling updates, even
/// though direct mouse-wheel and scrollbar events continue to work.
@MainActor
final class DiffReviewSheetSession<Choice: Sendable> {
    private let cancellationChoice: Choice
    private var selectedChoice: Choice
    private var continuation: CheckedContinuation<Choice, Never>?
    private weak var sheetWindow: NSWindow?

    init(cancellationChoice: Choice) {
        self.cancellationChoice = cancellationChoice
        selectedChoice = cancellationChoice
    }

    var isActive: Bool { continuation != nil }

    func run(window: NSWindow, asSheetFor parent: NSWindow) async -> Choice {
        guard continuation == nil, window.sheetParent == nil,
            parent.attachedSheet == nil, !Task.isCancelled
        else { return cancellationChoice }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                selectedChoice = cancellationChoice
                self.continuation = continuation
                sheetWindow = window
                parent.beginSheet(window) { [weak self] _ in
                    self?.complete()
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    func finish(
        with choice: Choice,
        response: NSApplication.ModalResponse
    ) {
        guard continuation != nil else { return }
        selectedChoice = choice
        guard let sheetWindow, let parent = sheetWindow.sheetParent else {
            complete()
            return
        }
        parent.endSheet(sheetWindow, returnCode: response)
    }

    func cancel() {
        guard continuation != nil else { return }
        finish(with: cancellationChoice, response: .cancel)
    }

    private func complete() {
        guard let continuation else { return }
        let result = selectedChoice
        self.continuation = nil
        sheetWindow = nil
        selectedChoice = cancellationChoice
        continuation.resume(returning: result)
    }
}

/// Shared AppKit document for transient YAML and key-value diff reviews.
@MainActor
final class DiffTextDocument {
    let scrollView: NSScrollView
    private let textView: NSTextView

    init(
        lines: [DiffTextLine],
        identifierPrefix: String,
        accessibilityLabel: String
    ) {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("AppKit did not create a diff document text view")
        }
        self.scrollView = scrollView
        self.textView = textView

        textView.identifier = .init("\(identifierPrefix)-text")
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)

        TextDocumentGeometry.configureWhitespaceVisualization(
            textView,
            enabled: true
        )

        scrollView.identifier = .init("\(identifierPrefix)-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        TextDocumentGeometry.configure(
            textView,
            in: scrollView,
            wrapsToViewport: false
        )
        textView.textStorage?.setAttributedString(Self.attributedText(for: lines))
        updateWhitespaceRanges(for: lines)
        TextDocumentGeometry.update(
            textView,
            in: scrollView,
            wrapsToViewport: false
        )
        // Retain the factory document's viewport-filling behavior for short
        // diffs while TextKit keeps longer documents at their laid-out height.
        textView.autoresizingMask = [.width, .height]
    }

    var text: String {
        textView.string
    }

    var initialFirstResponder: NSView {
        textView
    }

    func showFindPanel(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
        let command = NSMenuItem()
        command.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(command)
    }

    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString())
        updateWhitespaceRanges(for: [])
    }

    func replace(lines: [DiffTextLine]) {
        textView.textStorage?.setAttributedString(Self.attributedText(for: lines))
        updateWhitespaceRanges(for: lines)
        TextDocumentGeometry.update(
            textView,
            in: scrollView,
            wrapsToViewport: false
        )
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private static func attributedText(for lines: [DiffTextLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let attributes = attributes(for: line.role)
            result.append(NSAttributedString(string: line.text, attributes: attributes))
            if index != lines.indices.last {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    private func updateWhitespaceRanges(for lines: [DiffTextLine]) {
        let ranges = Self.whitespaceRanges(for: lines)
        (textView.layoutManager as? WhitespaceLayoutManager)?
            .whitespaceVisualizationCharacterRanges = ranges
    }

    private static func whitespaceRanges(for lines: [DiffTextLine]) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges.reserveCapacity(lines.count)
        var location = 0
        for (index, line) in lines.enumerated() {
            let prefixLength: Int
            switch line.whitespaceScope {
            case .none:
                prefixLength = -1
            case .content:
                prefixLength = 0
            case .contentAfterDiffPrefix:
                prefixLength = 1
            }
            if prefixLength >= 0, line.text.utf16.count > prefixLength {
                // Exclude the synthetic newline joining this line to the next
                // one. Unified-diff lines additionally exclude their leading
                // context/addition/removal prefix.
                ranges.append(NSRange(
                    location: location + prefixLength,
                    length: line.text.utf16.count - prefixLength
                ))
            }
            location += line.text.utf16.count
            if index != lines.indices.last { location += 1 }
        }
        return ranges
    }

    private static func attributes(
        for role: DiffTextLineRole
    ) -> [NSAttributedString.Key: Any] {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        switch role {
        case .context:
            return [.font: regular, .foregroundColor: NSColor.labelColor]
        case .fileHeader:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        case .hunkHeader:
            return [
                .font: regular,
                .foregroundColor: NSColor.systemBlue,
                .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.10),
            ]
        case .addition:
            return [
                .font: regular,
                .foregroundColor: NSColor.systemGreen,
                .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.10),
            ]
        case .removal:
            return [
                .font: regular,
                .foregroundColor: NSColor.systemRed,
                .backgroundColor: NSColor.systemRed.withAlphaComponent(0.10),
            ]
        case .sectionHeader:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
        case .notice:
            return [.font: regular, .foregroundColor: NSColor.systemOrange]
        }
    }
}
