import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource viewport virtualization", .serialized)
struct ResourceViewportVirtualizationTests {
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
    private var storedFetchRequests: [ResourceViewRangeRequest] = []
    private var storedMetricInterests: [ResourceMetricInterestRequest] = []
    private var shouldDelayNextRange = false
    private var storedDelayedRequest: ResourceViewRangeRequest?
    private var delayedContinuation: CheckedContinuation<Void, Never>?

    init(rowCount: Int) {
        precondition(rowCount > 0)
        self.rowCount = rowCount
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

    func delayNextRange() {
        lock.withLock { shouldDelayNextRange = true }
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

    func discoverResources(
        sessionID: String,
        refresh: Bool
    ) async throws -> ResourceDiscoveryResult {
        ResourceDiscoveryResult(resources: [DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true,
            verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        ["default"]
    }

    func streamView(
        request: ResourceViewRequest
    ) -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { continuation in
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
            continuation.finish()
        }
    }

    func fetchViewRange(
        request: ResourceViewRangeRequest
    ) async throws -> ResourceViewRange {
        let delay = lock.withLock { () -> Bool in
            storedFetchRequests.append(request)
            guard shouldDelayNextRange else { return false }
            shouldDelayNextRange = false
            return true
        }
        if delay {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    storedDelayedRequest = request
                    delayedContinuation = continuation
                }
            }
        }

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
            rows: (start..<end).map(resourceRow)
        )
    }

    func updateMetricInterest(
        request: ResourceMetricInterestRequest
    ) async throws {
        lock.withLock { storedMetricInterests.append(request) }
    }

    func cancelView(
        sessionID: String,
        viewID: String,
        generation: UInt64
    ) async {}

    func closeSession(sessionID: String) async {}

    private func resourceRow(_ index: Int) -> ResourceRow {
        let name = "pod-\(index)"
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
