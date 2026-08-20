import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource list cell effects", .serialized)
struct ResourceListCellEffectsTests {
    @Test("initial range is baseline and later UID-pinned revisions highlight")
    func snapshotDeltaExpiryAndReplacement() async throws {
        let provider = ControlledCellEffectsWorkspaceProvider()
        let controller = makeCellEffectsWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)

        try await waitForCellEffects(stage: "initial request") {
            provider.requestCount == 1
        }
        #expect(provider.yieldSnapshot(
            rows: [cellEffectsRow(
                uid: "pod-old",
                status: "Running",
                restarts: 0,
                cpuUsage: 0.2
            )],
            first: true,
            last: true
        ))
        try await waitForCellEffects(stage: "initial row") {
            table.numberOfRows == 1
        }
        #expect(try highlightedCell(
            in: table,
            columnID: "status"
        ).renderedHighlightColor == nil)

        #expect(provider.yieldDelta(
            upserts: [cellEffectsRow(
                uid: "pod-old",
                status: "Ready",
                restarts: 1,
                cpuUsage: 0.3
            )]
        ))
        try await waitForCellEffects(stage: "changed cells") {
            text(in: table, columnID: "status") == "Ready"
                && (try? highlightedCell(
                    in: table,
                    columnID: "cpu"
                ).renderedHighlightColor) != nil
        }

        let ordinary = try #require(tableViewCell(
            in: table,
            columnID: "status"
        ) as? ResourceTextTableCellView)
        let usage = try #require(tableViewCell(
            in: table,
            columnID: "cpu"
        ) as? ResourceUsageTableCellView)
        let restarts = try #require(tableViewCell(
            in: table,
            columnID: "restarts"
        ) as? ResourceTextTableCellView)
        #expect(ordinary.renderedHighlightColor != nil)
        #expect(usage.renderedHighlightColor != nil)
        let expectedWarning = ResourceTableCellEffectsPolicy.systemDefault
            .backgroundColor(for: ResourceCellHighlightPresentation(
                emphasis: .warning,
                strength: 1
            ))
        #expect(restarts.renderedHighlightColor?.isEqual(expectedWarning) == true)
        let initialOrdinaryOpacity = try #require(colorAlpha(
            ordinary.renderedHighlightColor
        ))
        #expect(initialOrdinaryOpacity >= 0.27)

        try await waitForCellEffects(stage: "fade") {
            guard let current = try? highlightedCell(
                in: table,
                columnID: "status"
            ), current === ordinary,
                let opacity = colorAlpha(current.renderedHighlightColor)
            else { return false }
            return opacity > 0 && opacity < initialOrdinaryOpacity
        }

        try await waitForCellEffects(timeout: .seconds(3), stage: "expiry") {
            (try? highlightedCell(
                in: table,
                columnID: "status"
            ).renderedHighlightColor) == nil
                && (try? highlightedCell(
                    in: table,
                    columnID: "cpu"
                ).renderedHighlightColor) == nil
        }
        #expect(try highlightedCell(
            in: table,
            columnID: "status"
        ) === ordinary)
        #expect(try highlightedCell(
            in: table,
            columnID: "cpu"
        ) === usage)

        // Establish a live highlight, then replace the Pod with a same-name,
        // new-UID object. Reuse must not transfer UID-keyed transient state.
        #expect(provider.yieldDelta(
            upserts: [cellEffectsRow(
                uid: "pod-old",
                status: "Terminating",
                restarts: 1,
                cpuUsage: 0.3
            )]
        ))
        try await waitForCellEffects(stage: "terminating change") {
            (try? highlightedCell(
                in: table,
                columnID: "status"
            ).renderedHighlightColor) != nil
        }
        #expect(provider.yieldDelta(
            upserts: [cellEffectsRow(
                uid: "pod-new",
                status: "Recreated",
                restarts: 2,
                cpuUsage: 0.4
            )],
            removedUIDs: ["pod-old"],
            orderedUIDs: ["pod-new"],
            orderIsComplete: true
        ))
        try await waitForCellEffects(stage: "UID replacement") {
            text(in: table, columnID: "status") == "Recreated"
        }
        for columnID in ["status", "restarts", "cpu"] {
            #expect(try highlightedCell(
                in: table,
                columnID: columnID
            ).renderedHighlightColor == nil)
        }
    }

    @Test("background-only values leave hovered presentation untouched")
    func backgroundOnlyUpdatePreservesVisibleCells() async throws {
        let provider = ControlledCellEffectsWorkspaceProvider()
        let controller = makeCellEffectsWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)

        try await waitForCellEffects { provider.requestCount == 1 }
        #expect(provider.yieldSnapshot(
            rows: [cellEffectsRow(
                uid: "pod-api",
                status: "Pending",
                restarts: 0,
                cpuUsage: 0.1001,
                cpuTooltip: "first exact metric",
                measuredAt: 1_000
            )],
            first: true,
            last: true
        ))
        try await waitForCellEffects {
            text(in: table, columnID: "status") == "Pending"
        }
        let nameCell = try #require(tableViewCell(
            in: table,
            columnID: "name"
        ))
        let statusCell = try #require(tableViewCell(
            in: table,
            columnID: "status"
        ))
        let cpuCell = try #require(tableViewCell(
            in: table,
            columnID: "cpu"
        ))
        #expect(cpuCell.toolTip == "first exact metric")

        // CPU's exact sample, timestamp, and tooltip all change, but its
        // rounded text and pressure style remain identical. The visible
        // Status change confirms that this delta has been applied.
        #expect(provider.yieldDelta(upserts: [cellEffectsRow(
            uid: "pod-api",
            status: "Running",
            restarts: 0,
            cpuUsage: 0.1002,
            cpuTooltip: "second exact metric",
            measuredAt: 2_000
        )]))
        try await waitForCellEffects {
            text(in: table, columnID: "status") == "Running"
        }

        #expect(tableViewCell(in: table, columnID: "name") === nameCell)
        #expect(tableViewCell(in: table, columnID: "status") === statusCell)
        #expect(tableViewCell(in: table, columnID: "cpu") === cpuCell)
        #expect(cpuCell.toolTip == "first exact metric")
    }

    @Test("simple filter bold activates only after replacement snapshot completes")
    func filterEmphasisWaitsForCompleteSnapshot() async throws {
        let provider = ControlledCellEffectsWorkspaceProvider()
        let controller = makeCellEffectsWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try resourceTable(in: controller)
        let filter = try resourceFilter(in: controller)

        try await waitForCellEffects { provider.requestCount == 1 }
        #expect(provider.yieldSnapshot(
            rows: [cellEffectsRow(
                uid: "pod-api",
                name: "Api api",
                status: "Running",
                restarts: 0,
                cpuUsage: 0.1
            )],
            first: true,
            last: true
        ))
        // The table row count is published before the asynchronous range
        // fetch materializes its cells. Wait for rendered content so the
        // replacement stream can retain a real warm row.
        try await waitForCellEffects {
            text(in: table, columnID: "status") == "Running"
        }

        filter.stringValue = "name:api"
        filter.delegate?.controlTextDidChange?(Notification(
            name: NSControl.textDidChangeNotification,
            object: filter
        ))
        try await waitForCellEffects { provider.requestCount == 2 }

        // Warm rows remain visible and unstyled while the complete
        // replacement projection is assembled off-screen.
        #expect(provider.yieldSnapshot(
            rows: [cellEffectsRow(
                uid: "pod-api",
                name: "Api api",
                status: "api-ready",
                restarts: 0,
                cpuUsage: 0.2
            )],
            first: true,
            last: false
        ))
        try await waitForCellEffects {
            text(in: table, columnID: "status") == "Running"
        }
        #expect(!containsBoldText(try attributedText(
            in: table,
            columnID: "name"
        )))
        #expect(try highlightedCell(
            in: table,
            columnID: "status"
        ).renderedHighlightColor == nil)
        #expect(try highlightedCell(
            in: table,
            columnID: "cpu"
        ).renderedHighlightColor == nil)

        #expect(provider.yieldSnapshot(rows: [], first: false, last: true))
        #expect(text(in: table, columnID: "status") == "Running")
        #expect(provider.yieldReconciled(rowsVisible: 1))
        try await waitForCellEffects {
            text(in: table, columnID: "status") == "api-ready"
                && (try? attributedText(in: table, columnID: "name"))
                    .map(containsBoldText) == true
        }
        let nameText = try attributedText(in: table, columnID: "name")
        #expect(boldRanges(in: nameText) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
        ])
        #expect(!containsBoldText(try attributedText(
            in: table,
            columnID: "status"
        )))
    }
}
}

private final class ControlledCellEffectsWorkspaceProvider:
    RangeBackedTestWorkspaceProviding, @unchecked Sendable
{
    private final class StreamState: @unchecked Sendable {
        let request: ResourceViewRequest
        let continuation: AsyncThrowingStream<ResourceViewMessage, Error>.Continuation
        var nextSequence: UInt64 = 1

        init(
            request: ResourceViewRequest,
            continuation: AsyncThrowingStream<ResourceViewMessage, Error>.Continuation
        ) {
            self.request = request
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var streams: [StreamState] = []

    var requestCount: Int { lock.withLock { streams.count } }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true,
            verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { ["default"] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        AsyncThrowingStream { continuation in
            lock.withLock {
                streams.append(StreamState(
                    request: request,
                    continuation: continuation
                ))
            }
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}

    func closeSession(sessionID: String) async {
        let continuations = lock.withLock {
            streams.map(\.continuation)
        }
        continuations.forEach { $0.finish() }
    }

    @discardableResult
    func yieldSnapshot(
        rows: [ResourceRow],
        first: Bool,
        last: Bool
    ) -> Bool {
        guard let emission = nextEmission() else { return false }
        emission.state.continuation.yield(testSnapshotInvalidation(
            request: emission.state.request,
            sequence: emission.sequence,
            rows: rows,
            first: first
        ))
        return true
    }

    @discardableResult
    func yieldDelta(
        upserts: [ResourceRow],
        removedUIDs: Set<ResourceUID> = [],
        orderedUIDs: [ResourceUID] = [],
        orderIsComplete: Bool = false
    ) -> Bool {
        guard let emission = nextEmission() else { return false }
        emission.state.continuation.yield(testDeltaInvalidation(
            request: emission.state.request,
            sequence: emission.sequence,
            upserts: upserts,
            removedUIDs: removedUIDs,
            orderedUIDs: orderedUIDs,
            orderIsComplete: orderIsComplete
        ))
        return true
    }

    @discardableResult
    func yieldReconciled(rowsVisible: UInt64) -> Bool {
        guard let emission = nextEmission() else { return false }
        emission.state.continuation.yield(testReconciliation(
            request: emission.state.request,
            sequence: emission.sequence
        ))
        return true
    }

    private func nextEmission() -> (state: StreamState, sequence: UInt64)? {
        lock.withLock {
            guard let state = streams.last else { return nil }
            let sequence = state.nextSequence
            state.nextSequence &+= 1
            return (state, sequence)
        }
    }
}

private struct NoopCellEffectsOptionalResourceCatalogProvider:
    OptionalResourceCatalogProviding
{
    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog
    {
        throw CancellationError()
    }
}

@MainActor
private func makeCellEffectsWorkspace(
    provider: ControlledCellEffectsWorkspaceProvider
) -> ClusterWorkspaceWindowController {
    makeColumnPropagationWorkspace(
        session: OpenedClusterSession(
            sessionID: "cell-effects-session",
            contextName: "cell-effects-context",
            clusterName: "cell-effects-cluster",
            serverHostname: "effects.invalid",
            defaultNamespace: "default"
        ),
        provider: provider,
        optionalResourceCatalogProvider: NoopCellEffectsOptionalResourceCatalogProvider(),
        columnsConfigurationPath:
            "/tmp/kmgr-cell-effects-\(UUID().uuidString).yaml"
    )
}

private func cellEffectsRow(
    uid: ResourceUID,
    name: String = "api",
    status: String,
    restarts: Int64,
    cpuUsage: Double,
    cpuTooltip: String = "",
    measuredAt: Int64? = nil
) -> ResourceRow {
    ResourceRow(
        identity: ResourceIdentity(
            clusterSessionID: "cell-effects-session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "default",
            name: name,
            uid: uid
        ),
        cells: [
            Cell(columnID: "name", displayText: name, typedValue: .string(name)),
            Cell(
                columnID: "status",
                displayText: status,
                typedValue: .string(status)
            ),
            Cell(
                columnID: "restarts",
                displayText: String(restarts),
                typedValue: .integer(restarts)
            ),
            Cell(
                columnID: "cpu",
                displayText: "\(Int(cpuUsage * 1_000))m / 500m / 1",
                typedValue: .usage(ResourceUsageValue(
                    usage: cpuUsage,
                    request: 0.5,
                    limit: 1,
                    unit: "cores",
                    resourceName: "cpu",
                    measuredAtUnixMilliseconds: measuredAt
                )),
                tooltip: cpuTooltip
            ),
        ]
    )
}

@MainActor
private func resourceTable(
    in controller: ClusterWorkspaceWindowController
) throws -> NSTableView {
    let root = try #require(controller.window?.contentView)
    return try #require(cellEffectsDescendants(of: root)
        .compactMap { $0 as? NSTableView }
        .first { $0.accessibilityLabel() == "Kubernetes resources" })
}

@MainActor
private func resourceFilter(
    in controller: ClusterWorkspaceWindowController
) throws -> NSSearchField {
    let root = try #require(controller.window?.contentView)
    return try #require(cellEffectsDescendants(of: root)
        .compactMap { $0 as? NSSearchField }
        .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
}

@MainActor
private func tableViewCell(
    in table: NSTableView,
    columnID: String
) -> NSView? {
    let columnIndex = table.column(withIdentifier: .init(columnID))
    guard columnIndex >= 0, table.numberOfRows > 0 else { return nil }
    return table.view(atColumn: columnIndex, row: 0, makeIfNecessary: true)
}

@MainActor
private func highlightedCell(
    in table: NSTableView,
    columnID: String
) throws -> HighlightableResourceTableCellView {
    try #require(tableViewCell(
        in: table,
        columnID: columnID
    ) as? HighlightableResourceTableCellView)
}

@MainActor
private func text(in table: NSTableView, columnID: String) -> String? {
    tableViewCell(in: table, columnID: columnID)
        .flatMap { ($0 as? NSTableCellView)?.textField?.stringValue }
}

@MainActor
private func attributedText(
    in table: NSTableView,
    columnID: String
) throws -> NSAttributedString {
    try #require((tableViewCell(
        in: table,
        columnID: columnID
    ) as? NSTableCellView)?.textField?.attributedStringValue)
}

@MainActor
private func containsBoldText(_ value: NSAttributedString) -> Bool {
    !boldRanges(in: value).isEmpty
}

@MainActor
private func colorAlpha(_ color: NSColor?) -> CGFloat? {
    color?.usingColorSpace(.deviceRGB)?.alphaComponent
}

@MainActor
private func boldRanges(in value: NSAttributedString) -> [NSRange] {
    var result: [NSRange] = []
    value.enumerateAttribute(
        .font,
        in: NSRange(location: 0, length: value.length)
    ) { attribute, range, _ in
        guard let font = attribute as? NSFont,
            NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        else { return }
        result.append(range)
    }
    return result
}

@MainActor
private func cellEffectsDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(cellEffectsDescendants(of:))
}

@MainActor
private func waitForCellEffects(
    timeout: Duration = .seconds(2),
    stage: String = "condition",
    condition: @escaping @MainActor () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while try !condition() {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "CellEffectsTestTimeout",
                message: "Timed out waiting for resource-list cell effects: \(stage).",
                operation: "test resource-list cell effects"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
