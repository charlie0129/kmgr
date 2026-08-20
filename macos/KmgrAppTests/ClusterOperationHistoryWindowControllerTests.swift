import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Operation history window", .serialized)
struct ClusterOperationHistoryWindowControllerTests {
    @Test("floating table defaults to exact newest-first ordering and supports sorting")
    func tablePresentationAndSorting() throws {
        let rawOperationError =
            "dial tcp 10.0.0.8:6443:  connect: connection refused\nTLS handshake timeout"
        let suite = "kmgr-operation-window-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frameName = "OperationHistory-test-\(UUID().uuidString)"
        NSWindow.removeFrame(usingName: frameName)
        defer { NSWindow.removeFrame(usingName: frameName) }
        let controller = ClusterOperationHistoryWindowController(
            session: operationHistorySession,
            tableLayoutStore: TableLayoutStore(defaults: defaults),
            frameAutosaveName: frameName
        )
        controller.showWindow(nil)
        defer {
            controller.window?.setFrameAutosaveName("")
            controller.close()
        }
        controller.install(ClusterOperationHistorySnapshot(completed: [
            operationRecord(
                id: 1,
                state: .finished,
                name: "older",
                received: 1,
                started: 2_000_000_100,
                finished: 3_000_000_100
            ),
            operationRecord(
                id: 2,
                state: .failed,
                name: "newer",
                received: 10,
                started: 2_000_000_900,
                finished: 3_000_000_900,
                errorMessage: rawOperationError
            ),
        ]))

        let panel = try #require(controller.window as? NSPanel)
        let root = try #require(panel.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }.first)
        #expect(panel.level == NSWindow.Level.floating)
        #expect(panel.isFloatingPanel)
        #expect(table.numberOfRows == 2)
        #expect(table.tableColumns.count == 10)
        #expect(table.allowsColumnReordering)
        #expect(table.tableColumns.allSatisfy {
            $0.resizingMask.contains(NSTableColumn.ResizingOptions.userResizingMask)
        })
        #expect(table.sortDescriptors.first?.key == "operation-history.started")
        #expect(table.sortDescriptors.first?.ascending == false)
        #expect(cellText(table, column: "operation-history.target", row: 0)
            .contains("newer"))

        let old = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(
            key: "operation-history.received",
            ascending: true
        )]
        controller.tableView(table, sortDescriptorsDidChange: old)
        #expect(cellText(table, column: "operation-history.target", row: 0)
            .contains("older"))
        #expect(cellText(table, column: "operation-history.status-code", row: 1)
            == "403 Forbidden")
        #expect(cellText(table, column: "operation-history.error", row: 1)
            == rawOperationError)

        let rawConnectionError = "proxyconnect tcp:  EOF\nread: connection reset by peer"
        controller.setConnectionState(
            .reconnecting,
            errorMessage: rawConnectionError
        )
        let connectionError = try #require(
            descendants(of: root).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityIdentifier() == "operation-history.connection-error"
            }
        )
        #expect(connectionError.stringValue == "Connection: \(rawConnectionError)")
        #expect(connectionError.toolTip == rawConnectionError)
        #expect(!connectionError.isHidden)
    }

    @Test("Active Only filters retained completions without discarding them")
    func activeOnlyFilter() throws {
        let suite = "kmgr-operation-filter-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frameName = "OperationHistory-filter-\(UUID().uuidString)"
        NSWindow.removeFrame(usingName: frameName)
        defer { NSWindow.removeFrame(usingName: frameName) }
        let controller = ClusterOperationHistoryWindowController(
            session: operationHistorySession,
            tableLayoutStore: TableLayoutStore(defaults: defaults),
            frameAutosaveName: frameName
        )
        controller.showWindow(nil)
        defer {
            controller.window?.setFrameAutosaveName("")
            controller.close()
        }
        controller.install(ClusterOperationHistorySnapshot(
            active: [operationRecord(
                id: 3,
                state: .active,
                name: "watching",
                received: 50,
                started: 2_000_000_950
            )],
            completed: [operationRecord(
                id: 2,
                state: .finished,
                name: "listed",
                received: 10,
                started: 2_000_000_900,
                finished: 3_000_000_900
            )]
        ))

        let root = try #require(controller.window?.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }.first)
        let activeOnly = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "operation-history.active-only" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "operation-history.status" })
        #expect(table.numberOfRows == 2)
        #expect(status.stringValue.contains("1 active"))
        #expect(status.stringValue.contains("1 completed retained"))

        activeOnly.performClick(nil)
        #expect(table.numberOfRows == 1)
        #expect(cellText(table, column: "operation-history.state", row: 0) == "Active")
        activeOnly.performClick(nil)
        #expect(table.numberOfRows == 2)
    }

    private func cellText(_ table: NSTableView, column: String, row: Int) -> String {
        let index = table.column(withIdentifier: .init(column))
        guard index >= 0,
            let cell = table.view(atColumn: index, row: row, makeIfNecessary: true)
                as? NSTableCellView
        else { return "" }
        return cell.textField?.stringValue ?? ""
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private var operationHistorySession: OpenedClusterSession {
        OpenedClusterSession(
            sessionID: "operation-session",
            contextName: "production",
            clusterName: "cluster",
            serverHostname: "cluster.example",
            defaultNamespace: "default"
        )
    }

    private func operationRecord(
        id: UInt64,
        state: ClusterOperationState,
        name: String,
        received: UInt64,
        started: Int64,
        finished: Int64? = nil,
        errorMessage: String? = nil
    ) -> ClusterOperationRecord {
        ClusterOperationRecord(
            id: id,
            state: state,
            operation: state == .active ? "WATCH" : "LIST",
            resource: "pods",
            namespace: "default",
            name: name,
            httpStatusCode: state == .failed ? 403 : 200,
            bytesReceived: received,
            bytesSent: 1,
            startedAtUnixNanos: started,
            finishedAtUnixNanos: finished,
            errorMessage: errorMessage
        )
    }
}
}
