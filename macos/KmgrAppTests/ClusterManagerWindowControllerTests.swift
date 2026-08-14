import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Cluster manager table presentation")
struct ClusterManagerWindowControllerTests {
    @Test("cluster chooser supplies its own contextual keyboard help")
    func contextualShortcuts() {
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [] },
                openContext: { _ in throw CancellationError() }
            )
        )
        defer { controller.close() }

        #expect(controller.contextualShortcutSnapshot?.contextID == "cluster-chooser")
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("L") == false)
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("\u{2318}N") == true)
    }

    @Test("visible matching text uses folded bold ranges")
    func foldedSearchHighlighting() throws {
        let value = "Dévelopment cluster — PROD.example.test"
        let ranges = ClusterManagerSearchHighlighting.matchingRanges(
            in: value,
            query: "development prod"
        )

        #expect(ranges.count == 2)
        let source = value as NSString
        #expect(source.substring(with: ranges[0]) == "Dévelopment")
        #expect(source.substring(with: ranges[1]) == "PROD")

        let textField = NSTextField(labelWithString: "")
        ClusterManagerSearchHighlighting.apply(
            value,
            query: "development prod",
            color: .secondaryLabelColor,
            to: textField
        )
        #expect(textField.stringValue == value)

        let developmentFont = try #require(
            textField.attributedStringValue.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont
        )
        let separatorFont = try #require(
            textField.attributedStringValue.attribute(
                .font,
                at: NSMaxRange(ranges[0]),
                effectiveRange: nil
            ) as? NSFont
        )
        #expect(NSFontManager.shared.traits(of: developmentFont).contains(.boldFontMask))
        #expect(!NSFontManager.shared.traits(of: separatorFont).contains(.boldFontMask))
        #expect(
            textField.attributedStringValue.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
                == .secondaryLabelColor
        )
        #expect(textField.accessibilityValue() == value)
    }

    @Test("reused cells clear stale highlighting when search is empty")
    func reusedCellClearsHighlighting() throws {
        let textField = NSTextField(labelWithString: "")
        ClusterManagerSearchHighlighting.apply(
            "production",
            query: "prod",
            color: .labelColor,
            to: textField
        )
        ClusterManagerSearchHighlighting.apply(
            "staging",
            query: "",
            color: .labelColor,
            to: textField
        )

        #expect(textField.stringValue == "staging")
        let font = try #require(
            textField.attributedStringValue.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont
        )
        #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(ClusterManagerSearchHighlighting.matchingRanges(
            in: "staging",
            query: "   "
        ).isEmpty)
    }
}
}
