import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource viewport virtualization", .serialized)
struct ResourceViewportVirtualizationTests {
    @Test("production metric-interest cadence follows the launch setting")
    func productionMetricInterestCadence() {
        #expect(
            ResourceViewportTiming.production(metricsRefreshSeconds: 37)
                .metricInterestRefresh == .seconds(37)
        )
        #expect(ResourceViewportTiming.production.scrollDebounce == .milliseconds(80))
    }

    @Test("user scrolling supersedes a pending restored row")
    func userScrollSupersedesPendingRestoration() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 100)
        provider.delayNextRange()
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "scroll-restoration",
            restorationState: ClusterWindowRestorationState(
                contextName: "viewport-context",
                gvr: GVR(group: "", version: "v1", resource: "pods"),
                scrollAnchor: ScrollAnchor(
                    uid: "viewport-pod-1",
                    pixelOffsetFromTop: 0,
                    priorRowIndex: 1
                )
            )
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedRange()
            controller.close()
        }

        let table = try resourceTable(in: controller)
        let scrollView = try #require(table.enclosingScrollView)
        try await waitForViewport {
            table.numberOfRows == 100 && provider.delayedRequest != nil
        }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        scroll(table, to: 0)
        let topY = table.visibleRect.minY

        provider.releaseDelayedRange()
        try await waitForViewport {
            self.cellText(in: table, row: 0) == "pod-0"
        }

        #expect(table.rows(in: table.visibleRect).location == 0)
        #expect(abs(table.visibleRect.minY - topY) < 0.5)
    }

    @Test("live reordering keeps the resource list pinned to its top boundary")
    func liveReorderKeepsTopBoundaryPinned() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 100)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "top-reorder"
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 100
                && self.cellText(in: table, row: 0) == "pod-0"
        }
        scroll(table, to: 0)
        let topY = table.visibleRect.minY

        provider.swapFirstTwoRows()
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 2)
        try await waitForViewport {
            self.cellText(in: table, row: 0) == "pod-1"
                && self.cellText(in: table, row: 1) == "pod-0"
        }

        #expect(table.rows(in: table.visibleRect).location == 0)
        #expect(abs(table.visibleRect.minY - topY) < 0.5)
    }

    @Test("absolute table rows use bounded raced ranges and refreshed metric interest")
    func virtualizedScrollingViewport() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeColumnPropagationWorkspace(
            session: OpenedClusterSession(
                sessionID: "viewport-session",
                contextName: "viewport-context",
                clusterName: "viewport-cluster",
                serverHostname: "viewport.invalid",
                defaultNamespace: "default"
            ),
            provider: provider,
            optionalResourceCatalogProvider:
                NoopViewportOptionalResourceCatalogProvider(),
            columnsConfigurationPath:
                "/tmp/kmgr-viewport-\(UUID().uuidString).yaml",
            resourceViewportTiming: ResourceViewportTiming(
                scrollDebounce: .milliseconds(25),
                metricInterestRefresh: .milliseconds(60)
            )
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedRange()
            controller.close()
        }

        let root = try #require(controller.window?.contentView)
        let table = try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitForViewport {
            table.numberOfRows == 10_000
                && provider.fetchRequests.contains { $0.startIndex == 0 }
                && self.cellText(in: table, row: 0) == "pod-0"
        }
        #expect(table.verticalMotionCanBeginDrag == false)

        let initialFetch = try #require(provider.fetchRequests.first)
        #expect(initialFetch.length <= 512)
        #expect(provider.fetchRequests.allSatisfy { $0.length <= 512 })

        provider.delayNextRange()
        scroll(table, to: 5_000)
        try await waitForViewport {
            provider.delayedRequest.map {
                self.contains(tableRow: 5_000, request: $0)
            } == true
        }
        let racedRequest = try #require(provider.delayedRequest)

        scroll(table, to: 8_000)
        try await waitForViewport {
            guard let request = provider.fetchRequests.last else { return false }
            return request != racedRequest
                && self.contains(tableRow: 8_000, request: request)
                && self.cellText(in: table, row: 8_000) == "pod-8000"
        }
        let retainedRequest = try #require(provider.fetchRequests.last)
        #expect(retainedRequest.length <= 512)

        try await waitForViewport {
            provider.metricInterests.contains {
                $0.generation == retainedRequest.revision.generation
                    && $0.indexRevision == retainedRequest.revision.index
                    && $0.startIndex == retainedRequest.startIndex
                    && $0.length == retainedRequest.length
            }
        }
        let retainedInterest = ResourceMetricInterestRequest(
            sessionID: retainedRequest.sessionID,
            viewID: retainedRequest.viewID,
            generation: retainedRequest.revision.generation,
            indexRevision: retainedRequest.revision.index,
            startIndex: retainedRequest.startIndex,
            length: retainedRequest.length
        )
        let sendsBeforeRefresh = provider.metricInterests.filter {
            $0 == retainedInterest
        }.count
        try await waitForViewport {
            provider.metricInterests.filter { $0 == retainedInterest }.count
                > sendsBeforeRefresh
        }

        provider.releaseDelayedRange()
        try await Task.sleep(for: .milliseconds(100))
        #expect(cellText(in: table, row: 8_000) == "pod-8000")

        controller.close()
        try await Task.sleep(for: .milliseconds(30))
        let sendsAfterTeardown = provider.metricInterests.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(provider.metricInterests.count == sendsAfterTeardown)
    }

    @Test("invalid range failures remain visible while the watch stays healthy")
    func invalidRangeFailureIsNotSuppressed() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 100)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "range-invalid"
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let table = try resourceTable(in: controller)
        let statusLine = try workspaceStatusLine(in: controller)
        try await waitForViewport {
            table.numberOfRows == 100
                && self.cellText(in: table, row: 0) == "pod-0"
                && statusLine.stringValue.hasSuffix(" · Watching")
        }

        provider.failNextRange(
            ClusterManagerIssue(
                category: .validation,
                reason: "InvalidTestViewRange",
                message: "The requested test resource range is outside the current index.",
                operation: "fetch test resource range"
            )
        )
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 2)
        try await waitForViewport {
            statusLine.stringValue.contains("outside the current index")
                && statusLine.stringValue.contains("Watching")
        }

        provider.failNextRange(
            ClusterManagerIssue(
                category: .validation,
                reason: ClusterManagerIssue.staleResourceViewRevisionReason,
                message: "resource view revision is stale: requested index 2, current 3",
                operation: "fetch test resource range"
            )
        )
        provider.emitInvalidation(presentationRevision: 3, indexRevision: 3)
        try await waitForViewport {
            provider.fetchRequests.contains { $0.revision.presentation == 3 }
                && statusLine.stringValue.contains("outside the current index")
                && statusLine.stringValue.contains("Watching")
        }

        provider.emitInvalidation(presentationRevision: 4, indexRevision: 4)
        try await waitForViewport {
            !statusLine.stringValue.contains("outside the current index")
                && statusLine.stringValue.hasSuffix(" · Watching")
        }
    }

    @Test("stale selection projection races do not become inline errors")
    func staleSelectionProjectionIsSuppressed() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 100)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-projection-stale"
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let table = try resourceTable(in: controller)
        let statusLine = try workspaceStatusLine(in: controller)
        try await waitForViewport {
            table.numberOfRows == 100
                && self.cellText(in: table, row: 0) == "pod-0"
        }
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && !provider.selectionProjections.isEmpty
        }
        let projectionAttempts = provider.selectionProjectionAttempts

        provider.failNextSelectionProjection(
            ClusterManagerIssue(
                category: .validation,
                reason: ClusterManagerIssue.staleResourceViewRevisionReason,
                message: "resource view revision is stale: requested index 1, current 2",
                operation: "project test selection"
            )
        )
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 1)
        try await waitForViewport {
            provider.fetchRequests.contains { $0.revision.presentation == 2 }
                && provider.selectionProjectionAttempts > projectionAttempts
                && !statusLine.stringValue.contains("resource view revision is stale")
        }
    }

    @Test("cell copy stays full, selection-neutral, and reuse-safe at 50k rows")
    func capturedCellCopy() async throws {
        let longValue = "controller-with-a-very-long-generated-pod-name-"
            + String(repeating: "7b9d6f8c7d-", count: 12)
            + "x4k2p"
        let provider = ControlledViewportWorkspaceProvider(
            rowCount: 50_000,
            rowNames: [5: longValue]
        )
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "cell-copy"
        )
        controller.showWindow(nil)
        defer {
            NSPasteboard.general.clearContents()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 50_000
                && self.cellText(in: table, row: 5) == longValue
                && self.cellText(in: table, row: 7) == "pod-7"
        }

        let barItem = NSMenuItem(
            title: "Copy Cell",
            action: #selector(ClusterWorkspaceWindowController.copyResourceCell(_:)),
            keyEquivalent: "c"
        )
        #expect(!controller.validateMenuItem(barItem))
        table.mouseDown(with: try cellClick(
            table: table,
            row: 5,
            windowNumber: controller.window?.windowNumber ?? 0
        ))
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        #expect(table.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        #expect(NSPasteboard.general.string(forType: .string) == longValue)

        #expect(controller.validateMenuItem(barItem))
        NSPasteboard.general.setString("sentinel", forType: .string)
        controller.copyResourceCell(nil)
        #expect(NSPasteboard.general.string(forType: .string) == longValue)

        let selectedBeforeContextMenu = table.selectedRowIndexes
        let contextMenu = try #require(table.menu(for: try rightClick(
            table: table,
            row: 7,
            windowNumber: controller.window?.windowNumber ?? 0
        )))
        contextMenu.delegate?.menuNeedsUpdate?(contextMenu)
        let copyCell = try #require(contextMenu.item(withTitle: "Copy Cell"))
        #expect(copyCell.isEnabled)
        #expect(table.selectedRowIndexes == selectedBeforeContextMenu)
        let copyAction = try #require(copyCell.action)
        #expect(NSApp.sendAction(copyAction, to: copyCell.target, from: copyCell))
        #expect(NSPasteboard.general.string(forType: .string) == "pod-7")
        #expect(table.selectedRowIndexes == selectedBeforeContextMenu)

        scroll(table, to: 25_000)
        try await waitForViewport {
            self.cellText(in: table, row: 25_000) == "pod-25000"
        }
        NSPasteboard.general.setString("sentinel", forType: .string)
        #expect(table.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        #expect(NSPasteboard.general.string(forType: .string) == "pod-7")
        #expect(provider.fetchRequests.allSatisfy { $0.length <= 512 })
        #expect(provider.selectionPageRequests.isEmpty)
    }

    @Test("selection gestures serialize tokens and Command-A stays range projected")
    func tokenBackedSelection() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeColumnPropagationWorkspace(
            session: OpenedClusterSession(
                sessionID: "viewport-session",
                contextName: "viewport-context",
                clusterName: "viewport-cluster",
                serverHostname: "viewport.invalid",
                defaultNamespace: "default"
            ),
            provider: provider,
            optionalResourceCatalogProvider:
                NoopViewportOptionalResourceCatalogProvider(),
            columnsConfigurationPath:
                "/tmp/kmgr-selection-\(UUID().uuidString).yaml",
            resourceViewportTiming: ResourceViewportTiming(
                scrollDebounce: .milliseconds(25),
                metricInterestRefresh: .seconds(30)
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let table = try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectAll(nil)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && provider.selectionApplications[0].state.selectedCount == 10_000
                && !provider.selectionProjections.isEmpty
        }
        let commandAll = provider.selectionApplications[0]
        #expect(commandAll.gesture.kind == .commandAll)
        #expect(commandAll.previousToken.isEmpty)
        // AppKit receives only the resident range, never a 10,000-row IndexSet.
        #expect(table.selectedRowIndexes.count <= 512)

        // Queue two gestures without yielding. The second request must use the
        // first request's successful immutable token, not the earlier
        // Command-A token or AppKit's local indexes.
        table.selectRowIndexes(IndexSet(integer: 10), byExtendingSelection: false)
        table.selectRowIndexes(IndexSet(integer: 11), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 3
                && table.selectedRowIndexes == IndexSet(integer: 11)
        }
        let applications = provider.selectionApplications
        #expect(applications[1].gesture.index == 10)
        #expect(applications[1].previousToken == commandAll.state.token)
        #expect(applications[2].gesture.index == 11)
        #expect(applications[2].previousToken == applications[1].state.token)
    }

    @Test("Command-K captures a 250k Command-A without paging and deletes by token")
    func hugePaletteDeleteStaysBounded() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 250_000)
        let operationProvider = CapturingViewportSelectionDeleteProvider()
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-huge-palette-delete",
            operationProvider: operationProvider
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 250_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectAll(nil)
        try await waitForViewport {
            provider.selectionApplications.last?.state.selectedCount == 250_000
        }
        #expect(table.selectedRowIndexes.count <= 512)

        controller.showCommandPalette(nil)
        let paletteTable = try await waitForPaletteTable(in: controller)
        #expect(provider.selectionPageRequests.isEmpty)
        // A WATCH reorder after capture must not revoke the immutable token.
        // Preparation uses the newer current revision for its exact hidden
        // count, while the captured token/count/GVR remain unchanged.
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 2)
        try await waitForViewport {
            provider.fetchRequests.contains { $0.revision.index == 2 }
        }
        try activatePaletteRow(named: "Delete…", in: paletteTable)
        try await waitForViewport {
            operationProvider.preparedSelections.count == 1
        }

        let captured = try #require(operationProvider.preparedSelections.first)
        #expect(captured.selectedCount == 250_000)
        #expect(captured.token == provider.selectionApplications.last?.state.token)
        #expect(provider.selectionPageRequests.isEmpty)
        let sheet = try #require(controller.window?.attachedSheet)
        let previewTable = try #require(viewportDescendants(of: sheet.contentView!)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Resources awaiting deletion" })
        #expect(previewTable.numberOfRows <= 64)

        var foundDeleteButton: NSButton?
        try await waitForViewport {
            foundDeleteButton = viewportDescendants(of: sheet.contentView!)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Delete" && $0.isEnabled }
            return foundDeleteButton != nil
        }
        let deleteButton = try #require(foundDeleteButton)
        deleteButton.performClick(nil)
        try await waitForViewport {
            operationProvider.deletedSelections == [captured]
        }
        #expect(provider.selectionPageRequests.isEmpty)
    }

    @Test("Command-K gesture fence cannot be retargeted by a later gesture")
    func paletteSelectionFenceIsImmutable() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let operationProvider = CapturingViewportSelectionDeleteProvider()
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-palette-fence",
            operationProvider: operationProvider
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedSelectionApplication()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        provider.delayNextSelectionApplication()
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport { provider.hasDelayedSelection }

        // Command-K fences the accepted queue at row 5. Row 6 is accepted
        // afterward and may update the live table, but cannot mutate the
        // palette's immutable operation target.
        controller.showCommandPalette(nil)
        table.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        provider.releaseDelayedSelectionApplication()
        try await waitForViewport { provider.selectionApplications.count == 2 }
        let fencedToken = provider.selectionApplications[0].state.token
        let laterToken = provider.selectionApplications[1].state.token
        #expect(fencedToken != laterToken)

        let paletteTable = try await waitForPaletteTable(in: controller)
        try activatePaletteRow(named: "Delete…", in: paletteTable)
        try await waitForViewport {
            operationProvider.preparedSelections.count == 1
        }
        #expect(operationProvider.preparedSelections.first?.token == fencedToken)
        #expect(operationProvider.preparedSelections.first?.token != laterToken)
        #expect(provider.selectionPageRequests.isEmpty)
    }

    @Test("direct table Delete passes the immutable token without identity paging")
    func directTableDeleteUsesToken() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let operationProvider = CapturingViewportSelectionDeleteProvider()
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-direct-delete",
            operationProvider: operationProvider
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectAll(nil)
        try await waitForViewport {
            provider.selectionApplications.last?.state.selectedCount == 10_000
        }
        let token = try #require(provider.selectionApplications.last?.state.token)
        controller.deleteResourceSelection(nil)
        try await waitForViewport {
            operationProvider.preparedSelections.count == 1
        }
        #expect(operationProvider.preparedSelections.first?.token == token)
        #expect(provider.selectionPageRequests.isEmpty)
    }

    @Test("a stalled selection RPC retains at most 256 queued gestures")
    func selectionGestureQueueIsBounded() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-queue-cap"
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedSelectionApplication()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        provider.delayNextSelectionApplication()
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport { provider.hasDelayedSelection }
        for index in 0..<300 {
            table.selectRowIndexes(
                IndexSet(integer: 10 + index % 3),
                byExtendingSelection: false
            )
        }
        // The last accepted gesture targets row 10. Later delegate callbacks
        // are consumed and cannot alter AppKit's optimistic endpoint.
        #expect(table.selectedRowIndexes == IndexSet(integer: 10))

        provider.releaseDelayedSelectionApplication()
        try await waitForViewport {
            provider.selectionApplications.count == 257
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(provider.selectionApplicationAttempts == 257)

        table.keyDown(with: try arrowKey(
            keyCode: 125,
            modifiers: [.shift],
            windowNumber: controller.window?.windowNumber ?? 0
        ))
        try await waitForViewport { provider.selectionApplications.count == 258 }
        #expect(provider.selectionApplications.last?.gesture.kind == .shiftExtend)
        #expect(provider.selectionApplications.last?.gesture.index == 11)
    }

    @Test("cell-only revisions continue tokens and index revisions start fresh")
    func selectionRevisionRaces() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-revisions"
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedSelectionApplication()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && !provider.selectionProjections.isEmpty
                && table.selectedRowIndexes.contains(5)
        }
        let first = provider.selectionApplications[0]

        provider.emitInvalidation(presentationRevision: 2, indexRevision: 1)
        try await waitForViewport {
            provider.fetchRequests.contains {
                $0.revision.presentation == 2 && $0.revision.index == 1
            }
        }
        table.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        try await waitForViewport { provider.selectionApplications.count == 2 }
        #expect(provider.selectionApplications[1].previousToken == first.state.token)

        provider.delayNextSelectionApplication()
        table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false)
        try await waitForViewport { provider.hasDelayedSelection }
        table.selectRowIndexes(IndexSet(integer: 5_000), byExtendingSelection: false)
        provider.emitInvalidation(presentationRevision: 3, indexRevision: 2)
        try await waitForViewport {
            provider.fetchRequests.contains { $0.revision.index == 2 }
                && !table.selectedRowIndexes.contains(5_000)
        }
        provider.releaseDelayedSelectionApplication()
        try await waitForViewport { provider.selectionApplications.count == 3 }
        try await Task.sleep(for: .milliseconds(40))
        #expect(provider.selectionApplicationAttempts == 3)

        table.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: false)
        try await waitForViewport { provider.selectionApplications.count == 4 }
        #expect(provider.selectionApplications[3].previousToken.isEmpty)
    }

    @Test("a failed first gesture rolls back its optimistic table highlight")
    func failedSelectionRollsBack() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        provider.failNextSelectionApplication()
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-failure"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 9), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplicationAttempts == 1
                && table.selectedRowIndexes.isEmpty
        }
        #expect(provider.selectionApplications.isEmpty)
    }

    @Test("a failed gesture restores the last committed Shift-arrow endpoint")
    func failedGestureRestoresCommittedEndpoint() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-failed-endpoint"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }
        let committed = provider.selectionApplications[0]

        provider.failNextSelectionApplication()
        table.selectRowIndexes(IndexSet(integer: 9), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplicationAttempts == 2
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }

        table.keyDown(with: try arrowKey(
            keyCode: 125,
            modifiers: [.shift],
            windowNumber: controller.window?.windowNumber ?? 0
        ))
        try await waitForViewport { provider.selectionApplications.count == 2 }
        let extensionGesture = provider.selectionApplications[1]
        #expect(extensionGesture.gesture.kind == .shiftExtend)
        #expect(extensionGesture.gesture.index == 6)
        #expect(extensionGesture.previousToken == committed.state.token)
    }

    @Test("clicks against warm rows replay by UID on the fresh ordering")
    func staleIndexClickReplaysByUID() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-stale-click"
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedRange()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes == IndexSet(integer: 4)
        }
        let attemptsBeforeClick = provider.selectionApplicationAttempts
        let previousToken = try #require(
            provider.selectionApplications.last?.state.token
        )

        provider.delayNextRange()
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 2)
        try await waitForViewport { provider.delayedRequest?.revision.index == 2 }
        table.mouseDown(with: try rowClick(
            table: table,
            row: 8,
            windowNumber: controller.window?.windowNumber ?? 0
        ))

        #expect(provider.selectionApplicationAttempts == attemptsBeforeClick)
        #expect(table.selectedRowIndexes == IndexSet(integer: 8))

        provider.releaseDelayedRange()
        try await waitForViewport {
            provider.selectionApplications.count == 2
                && table.selectedRowIndexes == IndexSet(integer: 8)
        }
        let replay = try #require(provider.selectionApplications.last)
        #expect(replay.previousToken == previousToken)
        #expect(replay.gesture.kind == .replace)
        #expect(replay.gesture.index == nil)
        #expect(replay.gesture.targetUID == "viewport-pod-8")
    }

    @Test("Shift-click against warm rows carries stable anchor and target UIDs")
    func staleShiftClickReplaysStableRange() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-stale-shift"
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedRange()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try await waitForViewport { provider.selectionApplications.count == 1 }

        provider.delayNextRange()
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 2)
        try await waitForViewport { provider.delayedRequest?.revision.index == 2 }
        table.mouseDown(with: try rowClick(
            table: table,
            row: 8,
            modifiers: [.shift],
            windowNumber: controller.window?.windowNumber ?? 0
        ))
        #expect(table.selectedRowIndexes == IndexSet(integersIn: 4...8))
        #expect(provider.selectionApplicationAttempts == 1)

        provider.releaseDelayedRange()
        try await waitForViewport {
            provider.selectionApplications.count == 2
                && table.selectedRowIndexes == IndexSet(integersIn: 4...8)
        }
        let replay = try #require(provider.selectionApplications.last)
        #expect(replay.gesture.kind == .shiftExtend)
        #expect(replay.gesture.targetUID == "viewport-pod-8")
        #expect(replay.gesture.anchorUID == "viewport-pod-4")
    }

    @Test("a warm-row selection clears quietly when its UID disappears")
    func staleSelectionTargetCanDisappear() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-stale-disappeared"
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedRange()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try await waitForViewport { provider.selectionApplications.count == 1 }
        provider.delayNextRange()
        provider.emitInvalidation(presentationRevision: 2, indexRevision: 2)
        try await waitForViewport { provider.delayedRequest?.revision.index == 2 }
        table.mouseDown(with: try rowClick(
            table: table,
            row: 8,
            windowNumber: controller.window?.windowNumber ?? 0
        ))
        #expect(table.selectedRowIndexes == IndexSet(integer: 8))

        provider.makeStableSelectionUIDDisappear("viewport-pod-8")
        provider.releaseDelayedRange()
        try await waitForViewport {
            provider.selectionApplicationAttempts == 2
                && table.selectedRowIndexes == IndexSet(integer: 4)
        }
        #expect(provider.selectionApplications.count == 1)
    }

    @Test("closing during a delayed gesture prevents later selection publication")
    func closeCancelsDelayedGesturePublication() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-close-race"
        )
        controller.showWindow(nil)
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        provider.delayNextSelectionApplication()
        table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false)
        try await waitForViewport { provider.hasDelayedSelection }
        let projectionsBeforeClose = provider.selectionProjections.count
        controller.close()
        #expect(table.selectedRowIndexes.isEmpty)

        provider.releaseDelayedSelectionApplication()
        try await Task.sleep(for: .milliseconds(80))
        #expect(provider.selectionProjections.count == projectionsBeforeClose)
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test("selection expiry clears token-owned count and highlights without another RPC")
    func selectionExpiresLocally() async throws {
        let provider = ControlledViewportWorkspaceProvider(
            rowCount: 10_000,
            selectionLifetime: 0.12
        )
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-expiry"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 12), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes.contains(12)
        }
        try await waitForViewport { table.selectedRowIndexes.isEmpty }
    }

    @Test("double-click dispatches Enter after token-backed selection")
    func doubleClickEntersSelection() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-double-click"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        let location = table.convert(
            NSPoint(x: 8, y: table.rect(ofRow: 4).midY),
            to: nil
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        table.mouseDown(with: event)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && provider.selectionPageOffsets == [0]
        }
    }

    @Test("offscreen single selection is paged once for Columns preview")
    func offscreenColumnsPreview() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-columns"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        let root = try #require(controller.window?.contentView)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes.contains(5)
        }
        scroll(table, to: 5_000)
        try await waitForViewport {
            self.cellText(in: table, row: 5_000) == "pod-5000"
                && table.selectedRowIndexes.isEmpty
        }

        var request: ResourceColumnsRequest?
        controller.onShowColumns = { request = $0 }
        let button = try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Columns…" })
        button.performClick(nil)
        try await waitForViewport { request != nil }

        #expect(request?.previewContext.selectedObject?.uid == "viewport-pod-5")
        #expect(provider.selectionPageRequests.count == 1)
        #expect(provider.selectionPageRequests[0].offset == 0)
        #expect(provider.selectionPageRequests[0].limit == 1)
    }

    @Test("Columns waits for a delayed gesture and previews its token identity")
    func columnsWaitsForDelayedGesture() async throws {
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-columns-race"
        )
        controller.showWindow(nil)
        defer {
            provider.releaseDelayedSelectionApplication()
            controller.close()
        }
        let table = try resourceTable(in: controller)
        let root = try #require(controller.window?.contentView)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        provider.delayNextSelectionApplication()
        table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false)
        try await waitForViewport { provider.hasDelayedSelection }
        var request: ResourceColumnsRequest?
        controller.onShowColumns = { request = $0 }
        let button = try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Columns…" })
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(request == nil)

        provider.releaseDelayedSelectionApplication()
        try await waitForViewport { request != nil }
        #expect(request?.previewContext.selectedObject?.uid == "viewport-pod-7")
        #expect(provider.selectionPageRequests.last?.limit == 1)
    }

    @Test("scrolling token selection offscreen does not cancel pending Enter")
    func offscreenSelectionKeepsPendingEnter() async throws {
        let detailGate = ViewportDetailGate()
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-enter",
            objectDetailProvider: ViewportObjectDetailProvider(gate: detailGate)
        )
        controller.showWindow(nil)
        defer {
            Task { await detailGate.release() }
            controller.close()
        }
        let table = try resourceTable(in: controller)
        let root = try #require(controller.window?.contentView)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes.contains(5)
        }
        controller.enterResource(nil)
        try await waitForViewport { provider.selectionPageRequests.count == 1 }
        try await waitForViewportAsync { await detailGate.requestCount == 1 }

        scroll(table, to: 5_000)
        try await waitForViewport {
            self.cellText(in: table, row: 5_000) == "pod-5000"
                && table.selectedRowIndexes.isEmpty
        }
        await detailGate.release()
        try await waitForViewport {
            viewportDescendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }
    }

    @Test("trusted loaded restoration executes commands after its token expires")
    func loadedSelectionCommandFallback() async throws {
        let detailGate = ViewportDetailGate()
        await detailGate.release()
        let provider = ControlledViewportWorkspaceProvider(
            rowCount: 10_000,
            selectionLifetime: 0.8
        )
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-loaded-fallback",
            objectDetailProvider: ViewportObjectDetailProvider(gate: detailGate)
        )
        controller.showWindow(nil)
        defer { controller.close() }
        var table = try resourceTable(in: controller)
        let root = try #require(controller.window?.contentView)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        controller.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && !provider.selectionProjections.isEmpty
                && table.selectedRowIndexes.contains(5)
        }
        controller.enterResource(nil)
        try await waitForViewport {
            viewportDescendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }
        try await Task.sleep(for: .milliseconds(850))

        controller.navigateBack(nil)
        try await waitForViewport {
            viewportDescendants(of: root).compactMap { $0 as? NSTableView }
                .contains { table in
                    table.accessibilityLabel() == "Kubernetes resources"
                        && table.selectedRowIndexes.contains(5)
                }
        }
        table = try resourceTable(in: controller)
        controller.window?.makeFirstResponder(table)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        let pagesBeforeCopy = provider.selectionPageRequests.count
        controller.copyResourceName(nil)

        #expect(
            NSPasteboard.general.string(forType: .string) == "pod-5"
        )
        #expect(provider.selectionPageRequests.count == pagesBeforeCopy)
    }

    @Test("changing exact GVR clears token selection through history restore")
    func gvrChangeClearsSelection() async throws {
        let provider = ControlledViewportWorkspaceProvider(
            rowCount: 10_000,
            discoveredResources: [
                DiscoveredResource(
                    group: "", version: "v1", resource: "pods", kind: "Pod",
                    namespaced: true, verbs: ["list", "watch"]
                ),
                DiscoveredResource(
                    group: "", version: "v1", resource: "nodes", kind: "Node",
                    namespaced: false, verbs: ["list", "watch"]
                ),
            ]
        )
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-gvr-scope"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        var table = try resourceTable(in: controller)
        try await waitForViewport {
            provider.streamRequests.last?.resource.resource == "pods"
                && table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }
        try selectSidebarResource(kind: "Node", in: controller)
        try await waitForViewport {
            provider.streamRequests.last?.resource.resource == "nodes"
                && table.selectedRowIndexes.isEmpty
        }

        controller.navigateBack(nil)
        try await waitForViewport {
            provider.streamRequests.last?.resource.resource == "pods"
        }
        table = try resourceTable(in: controller)
        try await waitForViewport {
            self.cellText(in: table, row: 0) == "pod-0"
                && table.selectedRowIndexes.isEmpty
        }

        table.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        try await waitForViewport { provider.selectionApplications.count == 2 }
        #expect(provider.selectionApplications[1].previousToken.isEmpty)
    }

    @Test("changing namespace scope clears token selection through history restore")
    func namespaceChangeClearsSelection() async throws {
        let provider = ControlledViewportWorkspaceProvider(
            rowCount: 10_000,
            namespaceNames: ["default", "payments"]
        )
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-namespace-scope"
        )
        controller.showWindow(nil)
        defer { controller.close() }
        var table = try resourceTable(in: controller)
        let namespaceControl = try namespaceControl(in: controller)
        try await waitForViewport {
            namespaceControl.itemTitles.contains("payments")
                && table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }
        namespaceControl.selectItem(withTitle: "payments")
        _ = namespaceControl.sendAction(
            namespaceControl.action,
            to: namespaceControl.target
        )
        try await waitForViewport {
            provider.streamRequests.last.map {
                !$0.allNamespaces && $0.namespaces == ["payments"]
            } == true && table.selectedRowIndexes.isEmpty
        }

        controller.navigateBack(nil)
        try await waitForViewport {
            provider.streamRequests.last?.allNamespaces == true
                && namespaceControl.titleOfSelectedItem == "All namespaces"
        }
        table = try resourceTable(in: controller)
        try await waitForViewport {
            self.cellText(in: table, row: 0) == "pod-0"
                && table.selectedRowIndexes.isEmpty
        }
    }

    @Test("returning from same-list Details retains the selected identity")
    func detailsReturnRetainsSelection() async throws {
        let detailGate = ViewportDetailGate()
        await detailGate.release()
        let provider = ControlledViewportWorkspaceProvider(rowCount: 10_000)
        let controller = makeViewportWorkspace(
            provider: provider,
            suffix: "selection-details-return",
            objectDetailProvider: ViewportObjectDetailProvider(gate: detailGate)
        )
        controller.showWindow(nil)
        defer { controller.close() }
        var table = try resourceTable(in: controller)
        let root = try #require(controller.window?.contentView)
        try await waitForViewport {
            table.numberOfRows == 10_000
                && self.cellText(in: table, row: 0) == "pod-0"
        }

        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await waitForViewport {
            provider.selectionApplications.count == 1
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }
        controller.openResourceDetails(nil)
        try await waitForViewport {
            viewportDescendants(of: root).compactMap { $0 as? NSSegmentedControl }
                .contains { control in
                    control.segmentCount == 3
                        && control.label(forSegment: 0) == "Summary"
                }
        }

        controller.navigateBack(nil)
        table = try resourceTable(in: controller)
        try await waitForViewport {
            self.cellText(in: table, row: 5) == "pod-5"
                && table.selectedRowIndexes == IndexSet(integer: 5)
        }
    }

    private func makeViewportWorkspace(
        provider: ControlledViewportWorkspaceProvider,
        suffix: String,
        objectDetailProvider: (any ObjectDetailProviding)? = nil,
        operationProvider: (any ResourceOperationProviding)? = nil,
        restorationState: ClusterWindowRestorationState? = nil
    ) -> ClusterWorkspaceWindowController {
        makeColumnPropagationWorkspace(
            session: OpenedClusterSession(
                sessionID: "viewport-session",
                contextName: "viewport-context",
                clusterName: "viewport-cluster",
                serverHostname: "viewport.invalid",
                defaultNamespace: "default"
            ),
            provider: provider,
            optionalResourceCatalogProvider:
                NoopViewportOptionalResourceCatalogProvider(),
            objectDetailProvider: objectDetailProvider,
            operationProvider: operationProvider,
            columnsConfigurationPath:
                "/tmp/kmgr-\(suffix)-\(UUID().uuidString).yaml",
            resourceViewportTiming: ResourceViewportTiming(
                scrollDebounce: .milliseconds(10),
                metricInterestRefresh: .seconds(30)
            ),
            restorationState: restorationState
        )
    }

    private func resourceTable(
        in controller: ClusterWorkspaceWindowController
    ) throws -> NSTableView {
        let root = try #require(controller.window?.contentView)
        return try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
    }

    private func workspaceStatusLine(
        in controller: ClusterWorkspaceWindowController
    ) throws -> NSTextField {
        let root = try #require(controller.window?.contentView)
        return try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })
    }

    private func namespaceControl(
        in controller: ClusterWorkspaceWindowController
    ) throws -> NSPopUpButton {
        let window = try #require(controller.window)
        return try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.namespace"
        }?.view as? NSPopUpButton)
    }

    private func selectSidebarResource(
        kind: String,
        in controller: ClusterWorkspaceWindowController
    ) throws {
        let root = try #require(controller.window?.contentView)
        let outline = try #require(viewportDescendants(of: root)
            .compactMap { $0 as? NSOutlineView }
            .first)
        let row = try #require((0..<outline.numberOfRows).first { row in
            (outline.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) as? NSTableCellView)?.textField?.stringValue == kind
        })
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func arrowKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func rowClick(
        table: NSTableView,
        row: Int,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int
    ) throws -> NSEvent {
        let location = table.convert(
            NSPoint(x: 8, y: table.rect(ofRow: row).midY),
            to: nil
        )
        return try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func rightClick(
        table: NSTableView,
        row: Int,
        windowNumber: Int
    ) throws -> NSEvent {
        try cellClick(
            table: table,
            row: row,
            type: .rightMouseDown,
            windowNumber: windowNumber
        )
    }

    private func cellClick(
        table: NSTableView,
        row: Int,
        type: NSEvent.EventType = .leftMouseDown,
        windowNumber: Int
    ) throws -> NSEvent {
        let column = table.column(withIdentifier: .init("name"))
        guard table.tableColumns.indices.contains(column) else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "MissingNameColumn",
                message: "The resource table has no Name column.",
                operation: "test resource cell copy"
            )
        }
        let location = table.convert(
            NSPoint(
                x: table.rect(ofColumn: column).midX,
                y: table.rect(ofRow: row).midY
            ),
            to: nil
        )
        return try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func contains(
        tableRow: UInt64,
        request: ResourceViewRangeRequest
    ) -> Bool {
        let upper = request.startIndex + UInt64(request.length)
        return request.startIndex <= tableRow && tableRow < upper
    }

    private func scroll(_ table: NSTableView, to row: Int) {
        guard let scrollView = table.enclosingScrollView else { return }
        let y = max(0, table.rect(ofRow: row).minY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        table.layoutSubtreeIfNeeded()
    }

    private func waitForPaletteTable(
        in controller: ClusterWorkspaceWindowController
    ) async throws -> NSTableView {
        var result: NSTableView?
        try await waitForViewport {
            result = controller.window?.childWindows?.compactMap { $0.contentView }
                .flatMap(viewportDescendants(of:))
                .compactMap { $0 as? NSTableView }
                .first { $0.accessibilityLabel() == "Command palette results" }
            return result != nil
        }
        return try #require(result)
    }

    private func activatePaletteRow(
        named title: String,
        in table: NSTableView
    ) throws {
        let row = try #require((0..<table.numberOfRows).first { row in
            guard let cell = table.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) else { return false }
            return viewportDescendants(of: cell)
                .compactMap { $0 as? NSTextField }
                .first?.stringValue == title
        })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let action = try #require(table.doubleAction)
        #expect(NSApp.sendAction(action, to: table.target, from: table))
    }

    private func cellText(in table: NSTableView, row: Int) -> String? {
        let columnIndex = table.column(withIdentifier: .init("name"))
        guard table.tableColumns.indices.contains(columnIndex),
            let cell = table.view(
                atColumn: columnIndex,
                row: row,
                makeIfNecessary: true
            ) as? NSTableCellView
        else { return nil }
        return cell.textField?.stringValue
    }
}
}

private final class ControlledViewportWorkspaceProvider:
    WorkspaceResourceProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let rowCount: Int
    private let selectionLifetime: TimeInterval
    private let discoveredResources: [DiscoveredResource]
    private let namespaceNames: [String]
    private let rowNames: [Int: String]
    private var rowOrder: [Int]
    private var storedStreamRequests: [ResourceViewRequest] = []
    private var storedFetchRequests: [ResourceViewRangeRequest] = []
    private var storedMetricInterests: [ResourceMetricInterestRequest] = []
    private var shouldDelayNextRange = false
    private var nextRangeError: ClusterManagerIssue?
    private var storedDelayedRequest: ResourceViewRangeRequest?
    private var delayedContinuation: CheckedContinuation<Void, Never>?
    private var streamContinuation:
        AsyncThrowingStream<ResourceViewMessage, Error>.Continuation?
    private var streamGeneration: UInt64 = 0
    private var streamSequence: UInt64 = 0
    struct SelectionApplication: Sendable {
        var previousToken: String
        var gesture: ResourceSelectionGesture
        var state: ResourceSelectionState
    }
    struct SelectionPageRequest: Sendable {
        var token: String
        var offset: UInt64
        var limit: Int
    }
    private struct TestSelection {
        var indexes: Set<Int>
        var anchor: Int?
        var state: ResourceSelectionState
    }
    private var nextSelectionToken = 0
    private var selectionsByToken: [String: TestSelection] = [:]
    private var storedSelectionApplications: [SelectionApplication] = []
    private var storedSelectionProjections: [ResourceSelectionProjection] = []
    private var storedSelectionProjectionAttempts = 0
    private var storedSelectionApplicationAttempts = 0
    private var storedSelectionPageRequests: [SelectionPageRequest] = []
    private var failNextSelection = false
    private var delayNextSelection = false
    private var delayedSelectionContinuation: CheckedContinuation<Void, Never>?
    private var nextSelectionProjectionError: ClusterManagerIssue?
    private var missingStableSelectionUIDs: Set<ResourceUID> = []

    init(
        rowCount: Int,
        selectionLifetime: TimeInterval = 60 * 60,
        discoveredResources: [DiscoveredResource] = [
            DiscoveredResource(
                group: "",
                version: "v1",
                resource: "pods",
                kind: "Pod",
                namespaced: true,
                verbs: ["list", "watch"]
            ),
        ],
        namespaceNames: [String] = ["default"],
        rowNames: [Int: String] = [:]
    ) {
        precondition(rowCount > 0)
        precondition(!discoveredResources.isEmpty)
        self.rowCount = rowCount
        self.selectionLifetime = selectionLifetime
        self.discoveredResources = discoveredResources
        self.namespaceNames = namespaceNames
        self.rowNames = rowNames
        rowOrder = Array(0..<rowCount)
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    var fetchRequests: [ResourceViewRangeRequest] {
        lock.withLock { storedFetchRequests }
    }

    var metricInterests: [ResourceMetricInterestRequest] {
        lock.withLock { storedMetricInterests }
    }

    var delayedRequest: ResourceViewRangeRequest? {
        lock.withLock { storedDelayedRequest }
    }

    var selectionApplications: [SelectionApplication] {
        lock.withLock { storedSelectionApplications }
    }

    var selectionProjections: [ResourceSelectionProjection] {
        lock.withLock { storedSelectionProjections }
    }

    var selectionProjectionAttempts: Int {
        lock.withLock { storedSelectionProjectionAttempts }
    }

    var selectionApplicationAttempts: Int {
        lock.withLock { storedSelectionApplicationAttempts }
    }

    var selectionPageOffsets: [UInt64] {
        lock.withLock { storedSelectionPageRequests.map(\.offset) }
    }

    var selectionPageRequests: [SelectionPageRequest] {
        lock.withLock { storedSelectionPageRequests }
    }

    var hasDelayedSelection: Bool {
        lock.withLock { delayedSelectionContinuation != nil }
    }

    func delayNextRange() {
        lock.withLock { shouldDelayNextRange = true }
    }

    func failNextRange(_ error: ClusterManagerIssue) {
        lock.withLock { nextRangeError = error }
    }

    func swapFirstTwoRows() {
        lock.withLock {
            guard rowOrder.count > 1 else { return }
            rowOrder.swapAt(0, 1)
        }
    }

    func releaseDelayedRange() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer {
                delayedContinuation = nil
                storedDelayedRequest = nil
            }
            return delayedContinuation
        }
        continuation?.resume()
    }

    func failNextSelectionApplication() {
        lock.withLock { failNextSelection = true }
    }

    func delayNextSelectionApplication() {
        lock.withLock { delayNextSelection = true }
    }

    func releaseDelayedSelectionApplication() {
        let continuation = lock.withLock {
            let result = delayedSelectionContinuation
            delayedSelectionContinuation = nil
            return result
        }
        continuation?.resume()
    }

    func failNextSelectionProjection(_ error: ClusterManagerIssue) {
        lock.withLock { nextSelectionProjectionError = error }
    }

    func emitInvalidation(
        presentationRevision: UInt64,
        indexRevision: UInt64
    ) {
        let delivery = lock.withLock { () -> (
            AsyncThrowingStream<ResourceViewMessage, Error>.Continuation,
            UInt64,
            UInt64
        )? in
            guard let streamContinuation else { return nil }
            streamSequence &+= 1
            return (streamContinuation, streamGeneration, streamSequence)
        }
        guard let (continuation, generation, sequence) = delivery else { return }
        continuation.yield(.invalidation(
            cursor: StreamCursor(generation: generation, sequence: sequence),
            invalidation: ResourceViewInvalidation(
                presentationRevision: presentationRevision,
                indexRevision: indexRevision,
                rowsVisible: UInt64(rowCount),
                maxRangeLength:
                    ResourceViewInvalidation.protocolMaximumRangeLength
            )
        ))
    }

    func discoverResources(
        sessionID: String,
        refresh: Bool
    ) async throws -> ResourceDiscoveryResult {
        ResourceDiscoveryResult(resources: discoveredResources)
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        namespaceNames
    }

    func streamView(
        request: ResourceViewRequest
    ) -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { continuation in
            let finalSequence: UInt64 = request.stageUntilReconciled ? 3 : 2
            lock.withLock {
                storedStreamRequests.append(request)
                streamContinuation = continuation
                streamGeneration = request.generation
                streamSequence = finalSequence
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    guard self?.streamGeneration == request.generation else {
                        return
                    }
                    self?.streamContinuation = nil
                }
            }
            continuation.yield(.invalidation(
                cursor: StreamCursor(
                    generation: request.generation,
                    sequence: 1
                ),
                invalidation: ResourceViewInvalidation(
                    presentationRevision: 1,
                    indexRevision: 1,
                    rowsVisible: UInt64(rowCount),
                    maxRangeLength:
                        ResourceViewInvalidation.protocolMaximumRangeLength
                )
            ))
            continuation.yield(.status(
                cursor: StreamCursor(
                    generation: request.generation,
                    sequence: 2
                ),
                status: ResourceViewStatus(
                    freshness: .watching,
                    rowsVisible: UInt64(rowCount)
                )
            ))
            if request.stageUntilReconciled {
                continuation.yield(.reconciled(
                    cursor: StreamCursor(
                        generation: request.generation,
                        sequence: 3
                    ),
                    reconciliation: ResourceViewReconciliation(
                        rowsVisible: UInt64(rowCount),
                        presentationRevision: 1,
                        indexRevision: 1
                    )
                ))
            }
        }
    }

    func fetchViewRange(
        request: ResourceViewRangeRequest
    ) async throws -> ResourceViewRange {
        let (delay, injectedError, order) = lock.withLock { () -> (
            Bool, ClusterManagerIssue?, [Int]
        ) in
            storedFetchRequests.append(request)
            let injectedError = nextRangeError
            nextRangeError = nil
            guard shouldDelayNextRange else {
                return (false, injectedError, rowOrder)
            }
            shouldDelayNextRange = false
            return (true, injectedError, rowOrder)
        }
        if delay {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    storedDelayedRequest = request
                    delayedContinuation = continuation
                }
            }
        }

        if let injectedError { throw injectedError }

        guard request.startIndex <= UInt64(rowCount) else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "InvalidViewportRange",
                message: "The requested viewport is outside the test index.",
                operation: "fetch test viewport"
            )
        }
        let start = Int(request.startIndex)
        let end = min(rowCount, start + request.length)
        return ResourceViewRange(
            viewID: request.viewID,
            revision: request.revision,
            startIndex: request.startIndex,
            rowsVisible: UInt64(rowCount),
            rows: (start..<end).map { resourceRow(order[$0]) }
        )
    }

    func updateMetricInterest(
        request: ResourceMetricInterestRequest
    ) async throws {
        lock.withLock { storedMetricInterests.append(request) }
    }

    func applySelectionGesture(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        previousToken: String,
        gesture: ResourceSelectionGesture
    ) async throws -> ResourceSelectionState {
        let behavior = lock.withLock { () -> (fail: Bool, delay: Bool) in
            storedSelectionApplicationAttempts += 1
            let failure = failNextSelection
            failNextSelection = false
            let delay = delayNextSelection
            delayNextSelection = false
            return (failure, delay)
        }
        if behavior.delay {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    delayedSelectionContinuation = continuation
                }
            }
        }
        if behavior.fail {
            throw ClusterManagerIssue(
                category: .unavailable,
                reason: "InjectedSelectionFailure",
                message: "The test selection gesture failed.",
                operation: "apply test selection gesture"
            )
        }
        return try lock.withLock {
            var indexes = selectionsByToken[previousToken]?.indexes ?? []
            var anchor = selectionsByToken[previousToken]?.anchor
            let targetIndex: Int?
            if let targetUID = gesture.targetUID {
                guard !missingStableSelectionUIDs.contains(targetUID) else {
                    throw ClusterManagerIssue(
                        category: .notFound,
                        reason: "MissingTestSelectionTarget",
                        message: "The stable selection target disappeared.",
                        operation: "apply test selection gesture"
                    )
                }
                targetIndex = Self.viewportIndex(for: targetUID)
                guard targetIndex.map({ (0..<rowCount).contains($0) }) == true else {
                    throw ClusterManagerIssue(
                        category: .notFound,
                        reason: "MissingTestSelectionTarget",
                        message: "The stable selection target disappeared.",
                        operation: "apply test selection gesture"
                    )
                }
            } else {
                targetIndex = gesture.index.map(Int.init)
            }
            if let anchorUID = gesture.anchorUID {
                guard let stableAnchor = Self.viewportIndex(for: anchorUID),
                    (0..<rowCount).contains(stableAnchor)
                else {
                    throw ClusterManagerIssue(
                        category: .notFound,
                        reason: "MissingTestSelectionAnchor",
                        message: "The stable selection anchor disappeared.",
                        operation: "apply test selection gesture"
                    )
                }
                anchor = stableAnchor
            }
            switch gesture.kind {
            case .replace:
                let index = targetIndex!
                indexes = [index]
                anchor = index
            case .commandToggle:
                let index = targetIndex!
                if indexes.remove(index) == nil { indexes.insert(index) }
                anchor = index
            case .shiftExtend:
                let index = targetIndex!
                let fixed = anchor ?? index
                let range = Set(min(fixed, index)...max(fixed, index))
                indexes = gesture.additive ? indexes.union(range) : range
                anchor = fixed
            case .commandAll:
                indexes = Set(0..<rowCount)
            case .clear:
                indexes = []
                anchor = nil
            }
            nextSelectionToken += 1
            let token = "viewport-selection-\(nextSelectionToken)"
            let state = ResourceSelectionState(
                token: token,
                revision: ResourceSelectionRevision(
                    generation: generation,
                    indexRevision: indexRevision
                ),
                selectedCount: UInt64(indexes.count),
                anchor: anchor.map {
                    ResourceSelectionAnchor(
                        index: UInt64($0),
                        uid: ResourceUID("viewport-pod-\($0)")
                    )
                },
                expiresAt: Date().addingTimeInterval(selectionLifetime)
            )
            selectionsByToken[token] = TestSelection(
                indexes: indexes,
                anchor: anchor,
                state: state
            )
            storedSelectionApplications.append(SelectionApplication(
                previousToken: previousToken,
                gesture: gesture,
                state: state
            ))
            return state
        }
    }

    private static func viewportIndex(for uid: ResourceUID) -> Int? {
        let prefix = "viewport-pod-"
        guard uid.rawValue.hasPrefix(prefix) else { return nil }
        return Int(uid.rawValue.dropFirst(prefix.count))
    }

    func makeStableSelectionUIDDisappear(_ uid: ResourceUID) {
        _ = lock.withLock { missingStableSelectionUIDs.insert(uid) }
    }

    func projectSelectionRange(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        startIndex: UInt64,
        length: Int,
        token: String
    ) async throws -> ResourceSelectionProjection {
        let injectedError = lock.withLock {
            storedSelectionProjectionAttempts += 1
            let error = nextSelectionProjectionError
            nextSelectionProjectionError = nil
            return error
        }
        if let injectedError { throw injectedError }
        return try lock.withLock {
            guard let selection = selectionsByToken[token] else {
                throw ClusterManagerIssue(
                    category: .validation,
                    reason: "MissingTestSelection",
                    message: "The test selection token does not exist.",
                    operation: "project test selection"
                )
            }
            let available = max(0, rowCount - Int(startIndex))
            let count = min(length, available)
            let selected = (0..<count).map {
                selection.indexes.contains(Int(startIndex) + $0)
            }
            let anchorOffset = selection.anchor.flatMap { anchor in
                let offset = anchor - Int(startIndex)
                return selected.indices.contains(offset) ? offset : nil
            }
            let projection = ResourceSelectionProjection(
                viewID: viewID,
                revision: ResourceSelectionRevision(
                    generation: generation,
                    indexRevision: indexRevision
                ),
                startIndex: startIndex,
                rowsVisible: UInt64(rowCount),
                state: selection.state,
                selected: selected,
                anchorOffset: anchorOffset
            )
            storedSelectionProjections.append(projection)
            return projection
        }
    }

    func fetchSelectionPage(
        sessionID: String,
        viewID: String,
        token: String,
        offset: UInt64,
        limit: Int
    ) async throws -> ResourceSelectionPage {
        try lock.withLock {
            storedSelectionPageRequests.append(SelectionPageRequest(
                token: token,
                offset: offset,
                limit: limit
            ))
            guard let selection = selectionsByToken[token] else {
                throw ClusterManagerIssue(
                    category: .validation,
                    reason: "MissingTestSelection",
                    message: "The test selection token does not exist.",
                    operation: "page test selection"
                )
            }
            let ordered = selection.indexes.sorted()
            let start = Int(offset)
            let end = min(ordered.count, start + limit)
            let items = ordered[start..<end].map { index in
                ResourceSelectionPageItem(
                    pinnedIndex: UInt64(index),
                    identity: resourceRow(rowOrder[index]).identity
                )
            }
            return ResourceSelectionPage(
                state: selection.state,
                offset: offset,
                items: Array(items),
                nextOffset: UInt64(end),
                done: end == ordered.count
            )
        }
    }

    func cancelView(
        sessionID: String,
        viewID: String,
        generation: UInt64
    ) async {}

    func closeSession(sessionID: String) async {}

    private func resourceRow(_ index: Int) -> ResourceRow {
        let name = rowNames[index] ?? "pod-\(index)"
        return ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: "viewport-session",
                group: "",
                version: "v1",
                resource: "pods",
                namespace: "default",
                name: name,
                uid: ResourceUID("viewport-pod-\(index)")
            ),
            cells: [Cell(
                columnID: "name",
                displayText: name,
                typedValue: .string(name)
            )]
        )
    }
}

private struct NoopViewportOptionalResourceCatalogProvider:
    OptionalResourceCatalogProviding
{
    func discoverOptionalResources(
        _ request: OptionalResourceCatalogRequest
    ) async throws -> OptionalResourceCatalog {
        throw CancellationError()
    }
}

private actor ViewportDetailGate {
    private(set) var requestCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func detail(for identity: ResourceIdentity) async -> ObjectDetail {
        requestCount += 1
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        return ObjectDetail(
            identity: identity,
            resourceVersion: "viewport-rv",
            summaryFields: [ObjectSummaryField(
                sectionID: "containers",
                fieldID: "container:api",
                label: "Container",
                displayText: "api"
            )],
            containers: [PodContainerDetail(name: "api", kind: .regular)]
        )
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }
}

private struct ViewportObjectDetailProvider: ObjectDetailProviding {
    let gate: ViewportDetailGate

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        await gate.detail(for: identity)
    }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}

private final class CapturingViewportSelectionDeleteProvider:
    ResourceOperationProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private var storedPreparedSelections: [ResourceSelectionDeleteReference] = []
    private var storedDeletedSelections: [ResourceSelectionDeleteReference] = []

    var preparedSelections: [ResourceSelectionDeleteReference] {
        lock.withLock { storedPreparedSelections }
    }

    var deletedSelections: [ResourceSelectionDeleteReference] {
        lock.withLock { storedDeletedSelections }
    }

    func prepareDeleteSelection(
        selection: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision,
        previewLimit: Int
    ) async throws -> ResourceSelectionDeletePreparation {
        lock.withLock { storedPreparedSelections.append(selection) }
        let previewCount = min(previewLimit, 64)
        return ResourceSelectionDeletePreparation(
            selection: selection,
            currentRevision: currentRevision,
            hiddenCount: 17,
            expiresAt: Date().addingTimeInterval(300),
            preview: (0..<previewCount).map { index in
                ResourceDeleteTarget(identity: ResourceIdentity(
                    clusterSessionID: selection.sessionID,
                    group: selection.gvr.group,
                    version: selection.gvr.version,
                    resource: selection.gvr.resource,
                    namespace: "default",
                    name: "preview-\(index)",
                    uid: ResourceUID("preview-uid-\(index)")
                ))
            },
            previewTruncated: selection.selectedCount > UInt64(previewCount)
        )
    }

    func deleteSelection(
        selection: ResourceSelectionDeleteReference,
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        lock.withLock { storedDeletedSelections.append(selection) }
        let total = UInt32(selection.selectedCount)
        return AsyncThrowingStream { continuation in
            continuation.yield(OperationProgress(
                cursor: StreamCursor(generation: 1, sequence: 1),
                operationID: "viewport-token-delete",
                state: .succeeded,
                completedItems: total,
                totalItems: total,
                itemResults: [],
                aggregateOnly: true
            ))
            continuation.finish()
        }
    }

    func deleteResources(
        targets: [ResourceDeleteTarget],
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func scaleResource(
        identity: ResourceIdentity,
        replicas: Int32,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func rolloutRestart(
        identity: ResourceIdentity,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateMetadata(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws {}
}

@MainActor
private func viewportDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(viewportDescendants)
}

private enum ViewportTestTimeout: Error {
    case elapsed
}

@MainActor
private func waitForViewport(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { throw ViewportTestTimeout.elapsed }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForViewportAsync(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        guard clock.now < deadline else { throw ViewportTestTimeout.elapsed }
        try await Task.sleep(for: .milliseconds(10))
    }
}
