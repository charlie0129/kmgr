import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Cluster manager table presentation")
struct ClusterManagerWindowControllerTests {
    @Test("loaded context list collapses the hidden issue region")
    func loadedListCollapsesHiddenIssueRegion() async throws {
        let context = ClusterContextSummary(
            name: "local",
            clusterName: "local-cluster",
            serverHostname: "127.0.0.1",
            defaultNamespace: "default",
            sourcePaths: ["/tmp/kubeconfig"]
        )
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [context] },
                openContext: { _ in throw CancellationError() }
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let layout = try clusterManagerVerticalLayout(in: root)
        try await waitForClusterManagerTable(layout.tableView)
        root.layoutSubtreeIfNeeded()

        #expect(layout.issueView.isHidden)
        #expect(abs(layout.tableToSeparatorGap(in: root) - 8) < 0.5)
    }

    @Test("visible initial notice stays between the table and separator")
    func visibleInitialNoticeKeepsIssueRegion() async throws {
        let context = ClusterContextSummary(
            name: "local",
            clusterName: "local-cluster",
            serverHostname: "127.0.0.1",
            defaultNamespace: "default",
            sourcePaths: ["/tmp/kubeconfig"]
        )
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [context] },
                openContext: { _ in throw CancellationError() }
            ),
            initialNotice: ClusterManagerInitialNotice(
                title: "Previous session closed",
                message: "Choose another context to continue."
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let layout = try clusterManagerVerticalLayout(in: root)
        try await waitForClusterManagerTable(layout.tableView)
        root.layoutSubtreeIfNeeded()

        #expect(!layout.issueView.isHidden)
        #expect(layout.issueTitleLabel.stringValue == "Previous session closed")
        let gaps = layout.visibleIssueGaps(in: root)
        #expect(abs(gaps.tableToIssue - 8) < 0.5)
        #expect(abs(gaps.issueToSeparator - 8) < 0.5)
        #expect(layout.issueFrame(in: root).height > 0)
    }

    @Test("visible open error stays between the table and separator")
    func visibleOpenErrorKeepsIssueRegion() async throws {
        let context = ClusterContextSummary(
            name: "remote",
            clusterName: "production",
            serverHostname: "api.example.test",
            defaultNamespace: "default",
            sourcePaths: ["/tmp/kubeconfig"]
        )
        let issue = ClusterManagerIssue(
            category: .authentication,
            reason: "Unauthorized",
            message: "The cluster rejected the configured credentials.",
            httpStatusCode: 401,
            contextName: context.name,
            operation: "open cluster session"
        )
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [context] },
                openContext: { _ in throw issue }
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let layout = try clusterManagerVerticalLayout(in: root)
        try await waitForClusterManagerTable(layout.tableView)
        let openButton = try #require(clusterManagerDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Open selected cluster context" })
        #expect(openButton.isEnabled)
        openButton.performClick(nil)
        try await waitForClusterManagerIssue(
            layout,
            title: "Authentication failed"
        )
        root.layoutSubtreeIfNeeded()

        #expect(!layout.issueView.isHidden)
        let gaps = layout.visibleIssueGaps(in: root)
        #expect(abs(gaps.tableToIssue - 8) < 0.5)
        #expect(abs(gaps.issueToSeparator - 8) < 0.5)
        #expect(layout.issueFrame(in: root).height > 0)
    }

    @Test("context rows stay on one line and columns support user resizing")
    func singleLineResizableContextTable() async throws {
        let context = ClusterContextSummary(
            name: "a-context-name-long-enough-to-overflow-the-initial-column-width",
            clusterName: "production-cluster-with-a-long-display-name",
            serverHostname: "a-very-long-api-server-hostname.example.test",
            defaultNamespace: "a-long-default-namespace",
            sourcePaths: ["/tmp/a/very/long/kubeconfig/source/path/config"]
        )
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [context] },
                openContext: { _ in throw CancellationError() }
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let table = try #require(clusterManagerDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubeconfig contexts" })
        try await waitForClusterManagerTable(table)

        #expect(table.allowsColumnResizing)
        #expect(table.tableColumns.count == 4)
        for column in table.tableColumns {
            #expect(column.resizingMask.contains(.userResizingMask))
            #expect(column.resizingMask.contains(.autoresizingMask))

            let requestedWidth = column.minWidth + 37
            column.width = requestedWidth
            #expect(column.width == requestedWidth)

            let cell = try #require(table.view(
                atColumn: table.column(withIdentifier: column.identifier),
                row: 0,
                makeIfNecessary: true
            ) as? NSTableCellView)
            let textField = try #require(cell.textField)
            #expect(textField.maximumNumberOfLines == 1)
            #expect(textField.lineBreakMode == .byTruncatingMiddle)
            #expect(textField.cell?.usesSingleLineMode == true)
            #expect(textField.cell?.wraps == false)
        }
    }

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

@MainActor
private struct ClusterManagerVerticalLayout {
    var tableView: NSTableView
    var tableContainer: NSView
    var issueView: NSView
    var issueTitleLabel: NSTextField
    var separator: NSBox

    func tableToSeparatorGap(in root: NSView) -> CGFloat {
        let tableFrame = alignmentFrame(of: tableContainer, in: root)
        let separatorFrame = alignmentFrame(of: separator, in: root)
        return tableFrame.minY - separatorFrame.maxY
    }

    func issueFrame(in root: NSView) -> NSRect {
        issueView.convert(issueView.bounds, to: root)
    }

    func visibleIssueGaps(in root: NSView) -> (
        tableToIssue: CGFloat,
        issueToSeparator: CGFloat
    ) {
        let tableFrame = alignmentFrame(of: tableContainer, in: root)
        let issueFrame = alignmentFrame(of: issueView, in: root)
        let separatorFrame = alignmentFrame(of: separator, in: root)
        return (
            tableToIssue: tableFrame.minY - issueFrame.maxY,
            issueToSeparator: issueFrame.minY - separatorFrame.maxY
        )
    }

    private func alignmentFrame(of view: NSView, in root: NSView) -> NSRect {
        guard let superview = view.superview else {
            return view.convert(view.bounds, to: root)
        }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: root)
    }
}

@MainActor
private func clusterManagerVerticalLayout(
    in root: NSView
) throws -> ClusterManagerVerticalLayout {
    let descendants = clusterManagerDescendants(of: root)
    let table = try #require(descendants
        .compactMap { $0 as? NSTableView }
        .first { $0.accessibilityLabel() == "Kubeconfig contexts" })
    let tableContainer = try #require(table.enclosingScrollView?.superview)
    let issueTitle = try #require(descendants.first {
        $0.identifier?.rawValue == "cluster-manager-issue-title"
    } as? NSTextField)
    let issueView = try #require(issueTitle.superview?.superview)
    let separator = try #require(descendants
        .compactMap { $0 as? NSBox }
        .first { $0.boxType == .separator })
    return ClusterManagerVerticalLayout(
        tableView: table,
        tableContainer: tableContainer,
        issueView: issueView,
        issueTitleLabel: issueTitle,
        separator: separator
    )
}

@MainActor
private func clusterManagerDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(clusterManagerDescendants(of:))
}

@MainActor
private func waitForClusterManagerTable(
    _ table: NSTableView,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while table.numberOfRows != 1 {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for the context table row.",
                operation: "test Cluster Manager table presentation"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForClusterManagerIssue(
    _ layout: ClusterManagerVerticalLayout,
    title: String,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while layout.issueView.isHidden || layout.issueTitleLabel.stringValue != title {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for the Cluster Manager issue banner.",
                operation: "test Cluster Manager issue presentation"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
