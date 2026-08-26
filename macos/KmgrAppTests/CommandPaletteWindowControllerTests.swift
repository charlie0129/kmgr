import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Command palette window", .serialized)
struct CommandPaletteWindowControllerTests {
    @Test("result text is vertically centered within its row")
    func resultTextIsVerticallyCentered() throws {
        let controller = makePaletteController(provider: ControllablePaletteSearchProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let table = try paletteControls(in: controller).table
        let cell = try #require(table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        cell.layoutSubtreeIfNeeded()
        let labels = paletteDescendants(of: cell).compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == "Go to Pod" })
        let detail = try #require(labels.first { $0.stringValue == "pods" })
        let textFrame = cell.convert(title.bounds, from: title)
            .union(cell.convert(detail.bounds, from: detail))

        #expect(abs(textFrame.midY - cell.bounds.midY) <= 0.5)
    }

    @Test("long command-palette scope stays within the panel")
    func longScopeDoesNotWidenPanel() throws {
        let contextName = String(repeating: "context-", count: 100)
        let controller = makePaletteController(
            provider: ControllablePaletteSearchProvider(),
            contextName: contextName
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let scope = try #require(paletteDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix(contextName) })
        root.layoutSubtreeIfNeeded()

        #expect(root.frame.width <= window.contentLayoutRect.width + 0.5)
        #expect(scope.frame.maxX <= root.bounds.maxX + 0.5)
        #expect(scope.lineBreakMode == .byTruncatingTail)
    }

    @Test("Command-number chooses its ranked result and rows show trailing hints")
    func commandNumberChoosesRankedResult() throws {
        let resources = (1...10).map { index in
            DiscoveredResource(
                group: "example.io", version: "v1",
                resource: "resources-\(index)", kind: "Resource \(index)",
                namespaced: true, verbs: ["list"]
            )
        }
        let controller = makePaletteController(
            provider: ControllablePaletteSearchProvider(),
            resources: resources
        )
        var openedResource: DiscoveredResource?
        controller.onOpenResource = { openedResource = $0 }
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let table = try paletteControls(in: controller).table

        #expect(table.numberOfRows == 10)
        #expect(paletteShortcut(at: 0, in: table) == "⌘1")
        #expect(paletteShortcut(at: 8, in: table) == "⌘9")
        #expect(paletteShortcut(at: 9, in: table) == nil)

        let secondCell = try #require(table.view(
            atColumn: 0,
            row: 1,
            makeIfNecessary: true
        ))
        secondCell.layoutSubtreeIfNeeded()
        let secondShortcut = try #require(paletteDescendants(of: secondCell)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "command-palette.shortcut" })
        let shortcutFrame = secondCell.convert(secondShortcut.bounds, from: secondShortcut)
        #expect(shortcutFrame.maxX <= secondCell.bounds.maxX)
        #expect(secondCell.bounds.maxX - shortcutFrame.maxX <= 13)

        let event = try paletteCommandKeyEvent(
            "2",
            keyCode: 19,
            windowNumber: window.windowNumber
        )
        #expect(window.performKeyEquivalent(with: event))
        #expect(openedResource == resources[1])
    }

    @Test("Command-Return activates the selected result with its alternate destination")
    func commandReturnUsesAlternateDestination() throws {
        let controller = makePaletteController(
            provider: ControllablePaletteSearchProvider()
        )
        var activation: (DiscoveredResource, PaletteActivationDestination)?
        controller.onOpenResourceWithDestination = { resource, destination in
            activation = (resource, destination)
        }
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let table = try paletteControls(in: controller).table
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let event = try paletteCommandKeyEvent(
            "\r",
            keyCode: 36,
            windowNumber: window.windowNumber
        )
        #expect(window.performKeyEquivalent(with: event))
        #expect(activation?.0.resource == "pods")
        #expect(activation?.1 == .alternateWindow)
    }

    @Test("search field stays clear of full-size-titlebar traffic lights")
    func searchFieldAvoidsTrafficLights() throws {
        let controller = makePaletteController(provider: ControllablePaletteSearchProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let search = try paletteControls(in: controller).search
        let closeButton = try #require(window.standardWindowButton(.closeButton))
        root.layoutSubtreeIfNeeded()

        let searchFrame = root.convert(search.bounds, from: search)
        let closeFrame = root.convert(closeButton.bounds, from: closeButton)
        #expect(search.frame.height == 40)
        #expect(!searchFrame.intersects(closeFrame))
    }

    @Test("search viewport grows below the native text baseline")
    func searchViewportPreservesNativeBaseline() throws {
        let controller = makePaletteController(provider: ControllablePaletteSearchProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let search = try paletteControls(in: controller).search
        let cell = try #require(search.cell as? NSSearchFieldCell)
        let font = try #require(search.font)

        search.stringValue = "g"
        #expect(window.makeFirstResponder(search))
        search.layoutSubtreeIfNeeded()

        let fontLineHeight = ceil(
            font.ascender - font.descender + font.leading
        )
        let nativeSearch = NSSearchField(frame: search.bounds)
        nativeSearch.font = font
        let nativeCell = try #require(nativeSearch.cell as? NSSearchFieldCell)
        let nativeTextRect = nativeCell.searchTextRect(forBounds: nativeSearch.bounds)
        let textRect = cell.searchTextRect(forBounds: search.bounds)
        let editor = try #require(search.currentEditor() as? NSTextView)
        let textContainer = try #require(editor.textContainer)
        let layoutManager = try #require(editor.layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let baseline = editor.frame.minY
            + layoutManager.location(forGlyphAt: glyphRange.location).y
        let nativeBaseline = nativeTextRect.minY
            + nativeSearch.firstBaselineOffsetFromTop
        let unusedSpaceBelowText = editor.bounds.maxY
            - layoutManager.usedRect(for: textContainer).maxY

        #expect(search.isFlipped)
        #expect(textRect.height >= fontLineHeight + 4)
        #expect(textRect.minY == nativeTextRect.minY)
        #expect(textRect.maxY > nativeTextRect.maxY)
        #expect(baseline == nativeBaseline)
        #expect(unusedSpaceBelowText >= 4)
        #expect(editor.frame == textRect)
    }

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

    @Test("query revisions overlap through debounce and dismissal cancels all")
    func queryRevisionsOverlapUntilDismissal() async throws {
        let provider = ControllablePaletteSearchProvider()
        let controller = makePaletteController(provider: provider)
        controller.showWindow(nil)
        let controls = try paletteControls(in: controller)

        try enterPodSearch(controller: controller, controls: controls)
        controls.search.stringValue = "alpha"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controls.search
        ))
        try await waitForPalette { provider.requests.count == 1 }
        let first = try #require(provider.requests.first)

        controls.search.stringValue = "beta"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controls.search
        ))
        try await Task.sleep(for: .milliseconds(70))
        #expect(provider.requests.count == 1)
        #expect(provider.cancellations.isEmpty)

        try await waitForPalette { provider.requests.count == 2 }
        let requests = provider.requests
        #expect(provider.cancellations.isEmpty)
        #expect(requests.map(\.query) == ["alpha", "beta"])
        #expect(requests.map(\.queryRevision) == [first.queryRevision, first.queryRevision + 1])

        controller.close()
        try await waitForPalette { provider.cancellations.count == 2 }
        #expect(Set(provider.cancellations.map(\.queryRevision)) == Set(requests.map(\.queryRevision)))
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
    provider: any ObjectSearchProviding,
    resources: [DiscoveredResource]? = nil,
    contextName: String = "palette-context"
) -> CommandPaletteWindowController {
    CommandPaletteWindowController(
        context: .init(
            session: OpenedClusterSession(
                sessionID: "palette-session",
                contextName: contextName,
                clusterName: "palette-cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            resources: resources ?? [DiscoveredResource(
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
private func paletteShortcut(at row: Int, in table: NSTableView) -> String? {
    guard row >= 0,
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
    else { return nil }
    return paletteDescendants(of: cell)
        .compactMap { $0 as? NSTextField }
        .first {
            !$0.isHidden
                && $0.accessibilityIdentifier() == "command-palette.shortcut"
        }?.stringValue
}

@MainActor
private func paletteCommandKeyEvent(
    _ characters: String,
    keyCode: UInt16,
    windowNumber: Int
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
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
    private var storedRequests: [ObjectSearchRequest] = []
    private var continuations: [UInt64: AsyncThrowingStream<ObjectSearchMessage, Error>.Continuation] = [:]
    private var storedCancellations: [PaletteSearchCancellation] = []

    var request: ObjectSearchRequest? { lock.withLock { storedRequest } }
    var cachedRequest: CachedObjectSearchRequest? { lock.withLock { storedCachedRequest } }
    var requests: [ObjectSearchRequest] { lock.withLock { storedRequests } }
    var cancellations: [PaletteSearchCancellation] { lock.withLock { storedCancellations } }

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
                storedRequests.append(request)
                continuations[request.queryRevision] = continuation
            }
        }
    }

    func cancelSearch(
        sessionID: String,
        searchID: String,
        generation: UInt64,
        queryRevision: UInt64
    ) async {
        lock.withLock {
            storedCancellations.append(PaletteSearchCancellation(
                sessionID: sessionID,
                searchID: searchID,
                generation: generation,
                queryRevision: queryRevision
            ))
        }
    }

    func emit(
        results: [ObjectSearchResult],
        sequence: UInt64,
        issue: ClusterManagerIssue? = nil
    ) {
        let values = lock.withLock {
            (storedRequest, storedRequest.flatMap { continuations[$0.queryRevision] })
        }
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

private struct PaletteSearchCancellation: Sendable {
    let sessionID: String
    let searchID: String
    let generation: UInt64
    let queryRevision: UInt64
}

private enum PaletteWindowTestError: Error {
    case timedOut
}
