import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Command palette window", .serialized)
struct CommandPaletteWindowControllerTests {
    @Test("root kind query includes cached objects with unrelated names")
    func rootKindQueryIncludesCachedObjects() async throws {
        let provider = ControllablePaletteSearchProvider()
        provider.setCachedResponse(CachedObjectSearchResponse(
            results: [paletteObject(
                name: "api", uid: "pod-api", rank: 600,
                detail: "default · Pod"
            )],
            objectsExamined: 1,
            examinationTruncated: false
        ))
        let controller = makePaletteController(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let controls = try paletteControls(in: controller)

        controls.search.stringValue = "pods"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controls.search
        ))
        try await waitForPalette { provider.cachedRequest != nil }
        try await waitForPalette { paletteRow(named: "api", in: controls.table) != nil }

        let request = try #require(provider.cachedRequest)
        #expect(request.query == "pods")
        #expect(request.resourceFilters.count == 1)
        #expect(request.resourceFilters.first?.resource == "pods")
        #expect(paletteRow(named: "Go to Pod", in: controls.table) != nil)
        #expect(paletteRow(named: "Search Pod…", in: controls.table) != nil)
    }

    @Test("progressive results preserve the selected object identity across reranking")
    func progressiveResultsPreserveSelectionIdentity() async throws {
        let provider = ControllablePaletteSearchProvider()
        let controller = makePaletteController(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let controls = try paletteControls(in: controller)

        try enterPodSearch(controller: controller, controls: controls)
        controls.search.stringValue = "api"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controls.search
        ))
        try await waitForPalette { provider.request != nil }

        provider.emit(
            results: [
                paletteObject(name: "alpha", uid: "pod-alpha", rank: 200),
                paletteObject(name: "beta", uid: "pod-beta", rank: 100),
            ],
            sequence: 1
        )
        try await waitForPalette { controls.table.numberOfRows == 2 }
        let betaRow = try #require(paletteRow(named: "beta", in: controls.table))
        controls.table.selectRowIndexes(
            IndexSet(integer: betaRow),
            byExtendingSelection: false
        )

        provider.emit(
            results: [
                paletteObject(name: "gamma", uid: "pod-gamma", rank: 300),
                paletteObject(
                    name: "beta", uid: "pod-beta", rank: 50,
                    detail: "default · Pod · refreshed"
                ),
            ],
            sequence: 2
        )
        try await waitForPalette { controls.table.numberOfRows == 3 }

        let selectedRow = controls.table.selectedRow
        #expect(selectedRow == paletteRow(named: "beta", in: controls.table))
        #expect(paletteTitle(at: selectedRow, in: controls.table) == "beta")
    }

    @Test("structured scoped-search issues remain visible")
    func structuredIssueRemainsVisible() async throws {
        let provider = ControllablePaletteSearchProvider()
        let controller = makePaletteController(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let controls = try paletteControls(in: controller)

        try enterPodSearch(controller: controller, controls: controls)
        controls.search.stringValue = "api"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controls.search
        ))
        try await waitForPalette { provider.request != nil }

        provider.emit(
            results: [],
            sequence: 1,
            issue: ClusterManagerIssue(
                category: .authentication,
                reason: "Unauthorized",
                message: "Authentication failed (401).",
                httpStatusCode: 401,
                retryable: true,
                contextName: "palette-context",
                operation: "search Pod"
            )
        )
        try await waitForPalette {
            controls.status.stringValue.contains("HTTP 401")
        }

        #expect(controls.status.stringValue.contains("Authentication failed (401)."))
        #expect(controls.status.stringValue.contains("Operation: search Pod"))
        #expect(controls.status.stringValue.contains("Context: palette-context"))
        #expect(controls.status.stringValue.contains("Reason: Unauthorized"))
        #expect(controls.status.stringValue.contains("Retryable"))
        #expect(controls.status.toolTip?.contains("HTTP 401") == true)
        #expect(controls.status.textColor == .systemRed)
    }
}
}

@MainActor
private struct PaletteControls {
    let search: NSSearchField
    let table: NSTableView
    let status: NSTextField
}

@MainActor
private func makePaletteController(
    provider: any ObjectSearchProviding
) -> CommandPaletteWindowController {
    CommandPaletteWindowController(
        context: .init(
            session: OpenedClusterSession(
                sessionID: "palette-session",
                contextName: "palette-context",
                clusterName: "palette-cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            resources: [DiscoveredResource(
                group: "", version: "v1", resource: "pods", kind: "Pod",
                namespaced: true, verbs: ["list"]
            )],
            namespaces: [],
            namespaceScope: .namespace("default"),
            commandContext: CommandContext(firstResponder: .other),
            recentObjects: []
        ),
        objectSearchProvider: provider
    )
}

@MainActor
private func paletteControls(
    in controller: CommandPaletteWindowController
) throws -> PaletteControls {
    let root = try #require(controller.window?.contentView)
    let views = paletteDescendants(of: root)
    return PaletteControls(
        search: try #require(views.compactMap { $0 as? NSSearchField }.first {
            $0.accessibilityLabel() == "Command palette search"
        }),
        table: try #require(views.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Command palette results"
        }),
        status: try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Command palette status"
        })
    )
}

@MainActor
private func enterPodSearch(
    controller: CommandPaletteWindowController,
    controls: PaletteControls
) throws {
    controls.search.stringValue = "pod"
    controller.controlTextDidChange(Notification(
        name: NSControl.textDidChangeNotification,
        object: controls.search
    ))
    let row = try #require(paletteRow(named: "Search Pod…", in: controls.table))
    controls.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    #expect(controller.control(
        controls.search,
        textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:))
    ))
    #expect(controls.table.numberOfRows == 0)
}

@MainActor
private func paletteRow(named title: String, in table: NSTableView) -> Int? {
    (0..<table.numberOfRows).first { paletteTitle(at: $0, in: table) == title }
}

@MainActor
private func paletteTitle(at row: Int, in table: NSTableView) -> String? {
    guard row >= 0,
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
    else { return nil }
    return paletteDescendants(of: cell)
        .compactMap { $0 as? NSTextField }
        .first?.stringValue
}

@MainActor
private func paletteDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(paletteDescendants(of:))
}

@MainActor
private func waitForPalette(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw PaletteWindowTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func paletteObject(
    name: String,
    uid: ResourceUID,
    rank: Double,
    detail: String = "default · Pod"
) -> ObjectSearchResult {
    ObjectSearchResult(
        identity: ResourceIdentity(
            clusterSessionID: "palette-session",
            group: "", version: "v1", resource: "pods",
            namespace: "default", name: name, uid: uid
        ),
        displayText: name,
        detailText: detail,
        rank: rank,
        stale: false
    )
}

private final class ControllablePaletteSearchProvider: ObjectSearchProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequest: ObjectSearchRequest?
    private var storedCachedRequest: CachedObjectSearchRequest?
    private var cachedResponse = CachedObjectSearchResponse(
        results: [], objectsExamined: 0, examinationTruncated: false
    )
    private var continuation: AsyncThrowingStream<ObjectSearchMessage, Error>.Continuation?

    var request: ObjectSearchRequest? { lock.withLock { storedRequest } }
    var cachedRequest: CachedObjectSearchRequest? { lock.withLock { storedCachedRequest } }

    func setCachedResponse(_ value: CachedObjectSearchResponse) {
        lock.withLock { cachedResponse = value }
    }

    func searchCachedObjects(request: CachedObjectSearchRequest) async throws
        -> CachedObjectSearchResponse {
        lock.withLock {
            storedCachedRequest = request
            return cachedResponse
        }
    }

    func searchObjects(request: ObjectSearchRequest)
        -> AsyncThrowingStream<ObjectSearchMessage, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                storedRequest = request
                self.continuation = continuation
            }
        }
    }

    func cancelSearch(
        sessionID: String,
        searchID: String,
        generation: UInt64,
        queryRevision: UInt64
    ) async {}

    func emit(
        results: [ObjectSearchResult],
        sequence: UInt64,
        issue: ClusterManagerIssue? = nil
    ) {
        let values = lock.withLock { (storedRequest, continuation) }
        guard let request = values.0, let continuation = values.1 else { return }
        continuation.yield(ObjectSearchMessage(
            cursor: StreamCursor(generation: request.generation, sequence: sequence),
            queryRevision: request.queryRevision,
            results: results,
            progress: ObjectSearchProgress(
                queryRevision: request.queryRevision,
                objectsExamined: UInt64(results.count),
                complete: issue != nil,
                usedDirectGet: false,
                reusableSnapshotAvailable: false
            ),
            issue: issue
        ))
    }
}

private enum PaletteWindowTestError: Error {
    case timedOut
}
