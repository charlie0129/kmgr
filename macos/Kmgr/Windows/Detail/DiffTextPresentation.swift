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

struct DiffTextLine: Hashable, Sendable {
    var text: String
    var role: DiffTextLineRole
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
        textView.textStorage?.setAttributedString(Self.attributedText(for: lines))

        scrollView.identifier = .init("\(identifierPrefix)-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
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
