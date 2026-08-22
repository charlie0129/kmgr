import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Cluster manager table presentation")
struct ClusterManagerWindowControllerTests {
    @Test("loading surface follows a dark window appearance")
    func loadingSurfaceFollowsDarkAppearance() throws {
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        application.appearance = NSAppearance(named: .aqua)
        defer { application.appearance = originalAppearance }

        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in
                    try await Task.sleep(for: .seconds(30))
                    return []
                },
                openContext: { _ in throw CancellationError() }
            )
        )
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.showWindow(nil)
        defer { controller.close() }

        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let stateView = try #require(clusterManagerDescendants(of: root).first {
            $0.identifier?.rawValue == "cluster-manager-state-view"
        })
        #expect(!stateView.isHidden)

        window.appearance = NSAppearance(named: .darkAqua)
        root.layoutSubtreeIfNeeded()
        stateView.needsDisplay = true
        let bitmap = try #require(
            stateView.bitmapImageRepForCachingDisplay(in: stateView.bounds)
        )
        stateView.cacheDisplay(in: stateView.bounds, to: bitmap)
        let background = try #require(
            bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)
        )
        let maximumComponent = max(
            background.redComponent,
            max(background.greenComponent, background.blueComponent)
        )

        #expect(
            stateView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        )
        #expect(maximumComponent < 0.5)
    }

    @Test("empty-state icon uses the configured title spacing")
    func emptyStateIconUsesConfiguredTitleSpacing() async throws {
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [] },
                openContext: { _ in throw CancellationError() }
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let title = try await waitForClusterManagerLabel(
            "No kubeconfig contexts found",
            in: root
        )
        root.layoutSubtreeIfNeeded()
        let stack = try #require(title.superview as? NSStackView)
        let icon = try #require(stack.arrangedSubviews.first { $0 is NSImageView })
        let iconAlignment = icon.alignmentRect(forFrame: icon.frame)
        let titleAlignment = title.alignmentRect(forFrame: title.frame)

        #expect(abs(iconAlignment.minY - titleAlignment.maxY - 16) < 0.5)
    }

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

    @Test("long chooser notices stay within the configured window width")
    func longInitialNoticeDoesNotWidenWindow() throws {
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [] },
                openContext: { _ in throw CancellationError() }
            ),
            initialNotice: ClusterManagerInitialNotice(
                title: "Workspace restoration skipped",
                message: "Source: " + String(repeating: "/very-long-kubeconfig-segment", count: 400)
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let issueMessage = try #require(clusterManagerDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "cluster-manager-issue-message" })
        root.layoutSubtreeIfNeeded()

        #expect(root.frame.width <= window.contentLayoutRect.width + 0.5)
        #expect(issueMessage.frame.maxX <= root.bounds.maxX + 0.5)
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

    @Test("in-flight cluster connection can be cancelled and retried")
    func cancelInFlightOpenAndRetry() async throws {
        let context = ClusterContextSummary(
            name: "remote",
            clusterName: "production",
            serverHostname: "api.example.test",
            defaultNamespace: "default"
        )
        let attempts = ClusterOpenAttemptRecorder()
        let controller = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [context] },
                openContext: { reference in
                    await attempts.recordStart(reference)
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return OpenedClusterSession(
                            sessionID: "unexpected-session",
                            contextName: context.name,
                            clusterName: context.clusterName,
                            serverHostname: context.serverHostname,
                            defaultNamespace: context.defaultNamespace
                        )
                    } catch is CancellationError {
                        await attempts.recordCancellation(reference)
                        throw CancellationError()
                    }
                }
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let layout = try clusterManagerVerticalLayout(in: root)
        try await waitForClusterManagerTable(layout.tableView)
        let buttons = clusterManagerDescendants(of: root).compactMap { $0 as? NSButton }
        let openButton = try #require(buttons.first {
            $0.accessibilityLabel() == "Open selected cluster context"
        })
        let cancelButton = try #require(buttons.first {
            $0.accessibilityLabel() == "Cancel opening cluster context"
        })

        #expect(openButton.isEnabled)
        #expect(cancelButton.isHidden)
        openButton.performClick(nil)
        try await waitForClusterOpenAttempts(attempts, started: 1, cancelled: 0)

        #expect(!openButton.isEnabled)
        #expect(!cancelButton.isHidden)
        #expect(cancelButton.isEnabled)
        #expect(!layout.tableView.isEnabled)

        cancelButton.performClick(nil)
        #expect(openButton.isEnabled)
        #expect(cancelButton.isHidden)
        #expect(layout.tableView.isEnabled)

        // Retry before the cancelled task unwinds. Its late completion must not
        // clear the state for this replacement attempt.
        openButton.performClick(nil)
        try await waitForClusterOpenAttempts(attempts, started: 2, cancelled: 1)
        #expect(!openButton.isEnabled)
        #expect(!cancelButton.isHidden)
        #expect(!layout.tableView.isEnabled)

        cancelButton.performClick(nil)
        try await waitForClusterOpenAttempts(attempts, started: 2, cancelled: 2)
        #expect(openButton.isEnabled)
        #expect(cancelButton.isHidden)
        #expect(layout.tableView.isEnabled)
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
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("\u{2318}O") == true)
    }

    @Test("remembered kubeconfig paths bind both listing and opening")
    func rememberedKubeconfigPathsBindRequests() async throws {
        let suite = "kmgr-cluster-manager-source-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceStore = KubeconfigSourceStore(defaults: defaults)
        let sourcePath = "/tmp/custom-team-kubeconfig"
        #expect(sourceStore.add(paths: [sourcePath]))

        let context = ClusterContextSummary(
            name: "team",
            clusterName: "team-cluster",
            serverHostname: "api.team.example.test",
            defaultNamespace: "platform",
            sourcePaths: [sourcePath]
        )
        let requests = ClusterSourceRequestRecorder()
        let provider = AnyClusterContextProvider(
            listCatalog: { reload, paths in
                await requests.recordList(reload: reload, paths: paths)
                return ClusterContextCatalog(
                    contexts: [context],
                    addedKubeconfigSources: [
                        AddedKubeconfigSourceStatus(path: sourcePath, contextCount: 1),
                    ]
                )
            },
            openContext: { reference, paths in
                await requests.recordOpen(reference: reference, paths: paths)
                return OpenedClusterSession(
                    sessionID: "session-team",
                    contextName: context.name,
                    clusterName: context.clusterName,
                    serverHostname: context.serverHostname,
                    defaultNamespace: context.defaultNamespace
                )
            }
        )
        let controller = ClusterManagerWindowController(
            provider: provider,
            sourceStore: sourceStore,
            closesAfterOpening: false
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let table = try #require(clusterManagerDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubeconfig contexts" })
        try await waitForClusterManagerTable(table)
        try await waitForClusterSourceRequests(requests, listCount: 1, openCount: 0)

        let sourcesButton = try #require(clusterManagerDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Manage added kubeconfig files" })
        #expect(sourcesButton.title == "Kubeconfig Files (1)…")
        #expect(await requests.lastListPaths() == [sourcePath])

        let openButton = try #require(clusterManagerDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Open selected cluster context" })
        openButton.performClick(nil)
        try await waitForClusterSourceRequests(requests, listCount: 1, openCount: 1)
        let open = try #require(await requests.lastOpen())
        #expect(open.reference == context.id)
        #expect(open.paths == [sourcePath])
    }

    @Test("kubeconfig files popover lists only user files with actionable status")
    func kubeconfigFilesPopoverPresentation() throws {
        let validPath = "/tmp/team.yaml"
        let missingPath = "/tmp/missing.yaml"
        let missingIssue = ClusterManagerIssue(
            category: .notFound,
            reason: "KubeconfigFileMissing",
            message: "The kubeconfig file could not be found.",
            retryable: true,
            operation: "read added kubeconfig"
        )
        let controller = KubeconfigSourcesPopoverViewController()
        var removed: [String] = []
        controller.onRemove = { removed = $0 }
        controller.update(
            paths: [validPath, missingPath],
            statuses: [
                AddedKubeconfigSourceStatus(path: validPath, contextCount: 12),
                AddedKubeconfigSourceStatus(path: missingPath, issue: missingIssue),
            ]
        )
        let root = controller.view
        let descendants = clusterManagerDescendants(of: root)
        let table = try #require(descendants.compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Added kubeconfig files" })
        #expect(table.numberOfRows == 2)

        let statusColumn = table.column(withIdentifier: .init("status"))
        let validStatus = try #require(table.view(
            atColumn: statusColumn,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        let missingStatus = try #require(table.view(
            atColumn: statusColumn,
            row: 1,
            makeIfNecessary: true
        ) as? NSTableCellView)
        #expect(validStatus.textField?.stringValue == "12 contexts")
        #expect(missingStatus.textField?.stringValue == "Missing")

        let labels = descendants.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains {
            $0 == "Kmgr also reads $KUBECONFIG; when unset, it reads kubeconfig files in ~/.kube."
        })
        #expect(!labels.contains { $0.contains("Always enabled") })

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let removeButton = try #require(descendants.compactMap { $0 as? NSButton }
            .first {
                $0.accessibilityLabel()
                    == "Remove selected kubeconfig files from Kmgr"
            })
        #expect(removeButton.isEnabled)
        removeButton.performClick(nil)
        #expect(removed == [missingPath])
    }

    @Test("file drop feedback uses the footer without covering context rows")
    func fileDropFeedbackUsesFooter() async throws {
        let context = ClusterContextSummary(
            name: "visible-context",
            clusterName: "visible-cluster",
            serverHostname: "api.example.test",
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

        let descendants = clusterManagerDescendants(of: root)
        let dropTarget = try #require(layout.tableContainer as? KubeconfigDropView)
        let normalFooter = try #require(descendants.first {
            $0.identifier?.rawValue == "cluster-manager-normal-footer"
        })
        let dropFooter = try #require(descendants.first {
            $0.identifier?.rawValue == "cluster-manager-drop-footer"
        })
        let dropLabel = try #require(descendants.first {
            $0.identifier?.rawValue == "cluster-manager-drop-footer-label"
        } as? NSTextField)
        let tableFrame = layout.tableContainer.convert(layout.tableContainer.bounds, to: root)

        #expect(!normalFooter.isHidden)
        #expect(dropFooter.isHidden)
        #expect(dropTarget.layer?.borderWidth == 0)
        #expect(dropTarget.layer?.backgroundColor == nil)
        #expect(layout.tableView.numberOfRows == 1)
        #expect(layout.tableView.enclosingScrollView?.isHidden == false)

        dropTarget.updateDropState(fileCount: 3)
        root.layoutSubtreeIfNeeded()

        #expect(normalFooter.isHidden)
        #expect(!dropFooter.isHidden)
        #expect(dropLabel.stringValue == "Release to add 3 kubeconfig files")
        #expect(dropLabel.textColor == .labelColor)
        #expect(dropTarget.layer?.borderWidth == 2)
        #expect(layout.tableContainer.convert(layout.tableContainer.bounds, to: root)
            .equalTo(tableFrame))
        #expect(layout.tableView.enclosingScrollView?.isHidden == false)

        dropTarget.updateDropState(fileCount: nil)
        #expect(!normalFooter.isHidden)
        #expect(dropFooter.isHidden)
        #expect(dropTarget.layer?.borderWidth == 0)
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
private func waitForClusterManagerLabel(
    _ value: String,
    in root: NSView,
    timeout: Duration = .seconds(2)
) async throws -> NSTextField {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if let label = clusterManagerDescendants(of: root)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == value })
        {
            return label
        }
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for Cluster Manager state text.",
                operation: "test Cluster Manager state presentation"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
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

private actor ClusterOpenAttemptRecorder {
    private var startedReferences: [String] = []
    private var cancelledReferences: [String] = []

    func recordStart(_ reference: String) {
        startedReferences.append(reference)
    }

    func recordCancellation(_ reference: String) {
        cancelledReferences.append(reference)
    }

    func counts() -> (started: Int, cancelled: Int) {
        (startedReferences.count, cancelledReferences.count)
    }
}

private actor ClusterSourceRequestRecorder {
    private var lists: [(reload: Bool, paths: [String])] = []
    private var opens: [(reference: String, paths: [String])] = []

    func recordList(reload: Bool, paths: [String]) {
        lists.append((reload, paths))
    }

    func recordOpen(reference: String, paths: [String]) {
        opens.append((reference, paths))
    }

    func counts() -> (lists: Int, opens: Int) {
        (lists.count, opens.count)
    }

    func lastListPaths() -> [String]? { lists.last?.paths }
    func lastOpen() -> (reference: String, paths: [String])? { opens.last }
}

private func waitForClusterOpenAttempts(
    _ recorder: ClusterOpenAttemptRecorder,
    started: Int,
    cancelled: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await recorder.counts() != (started, cancelled) {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for cluster open attempt state.",
                operation: "test Cluster Manager connection cancellation"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func waitForClusterSourceRequests(
    _ recorder: ClusterSourceRequestRecorder,
    listCount: Int,
    openCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await recorder.counts() != (listCount, openCount) {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for kubeconfig source requests.",
                operation: "test Cluster Manager kubeconfig sources"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
