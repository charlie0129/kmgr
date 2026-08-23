import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Workspace status")
struct WorkspaceStatusTests {
    @Test("status channels choose urgent work without hiding connection state")
    func channelPriority() {
        var board = WorkspaceStatusBoard()
        board.set(WorkspaceStatus("12 Pods · Watching"), for: .content)
        board.set(WorkspaceStatus("47 API resources"), for: .discovery)
        board.set(WorkspaceStatus("180 MiB cached"), for: .warmCache)
        #expect(board.presented.text == "12 Pods · Watching · 180 MiB cached")

        board.set(WorkspaceStatus("Refreshing API resources…", busy: true), for: .discovery)
        #expect(board.presented.text == "Refreshing API resources…")
        #expect(board.presented.busy)

        board.set(WorkspaceStatus(
            "Object conflict",
            severity: .error,
            toolTip: "The UID changed."
        ), for: .content)
        #expect(board.presented.text == "Object conflict")
        #expect(board.presented.toolTip == "The UID changed.")

        board.set(WorkspaceStatus(
            "Discovery failed",
            severity: .error,
            toolTip: "One API group is unavailable."
        ), for: .discovery)
        #expect(board.presented.text == (
            "Object conflict · Discovery failed · 180 MiB cached"
        ))
        #expect(board.presented.toolTip?.contains("The UID changed.") == true)
        #expect(board.presented.toolTip?.contains("One API group is unavailable.") == true)

        board.set(nil, for: .content)
        #expect(board.presented.text == "Discovery failed")
    }

    @Test("warm-cache status reports cluster and global budgets without claiming RSS")
    func warmCacheStatus() throws {
        let status = try #require(WarmCacheWorkspaceStatus.make(
            authority: WarmCacheUsage(
                retainedViews: 2,
                retainedObjects: 300,
                retainedBytes: 180 << 20,
                evictableViews: 1,
                evictableObjects: 120,
                evictableBytes: 64 << 20,
                viewLimit: 8,
                objectLimit: 100_000,
                byteLimit: 4 << 30,
                budgetEvictions: 3
            ),
            global: WarmCacheUsage(
                retainedViews: 4,
                retainedObjects: 900,
                retainedBytes: 512 << 20,
                evictableViews: 2,
                evictableObjects: 320,
                evictableBytes: 128 << 20,
                viewLimit: 24,
                objectLimit: 250_000,
                byteLimit: 4 << 30,
                budgetEvictions: 5
            )
        ))

        #expect(status.text == (
            "Cache 180 MiB · global 512 MiB · evictions 3/5"
        ))
        #expect(status.toolTip?.contains("1 / 8 idle warm queries") == true)
        #expect(status.toolTip?.contains("120 / 100,000 idle warm objects") == true)
        #expect(status.toolTip?.contains("not process RSS") == true)
        #expect(WarmCacheWorkspaceStatus.make(
            authority: WarmCacheUsage(),
            global: WarmCacheUsage()
        ) == nil)
    }

    @Test("supplemental problems compose with normal content")
    func supplementalProblemsCompose() {
        var board = WorkspaceStatusBoard()
        board.set(WorkspaceStatus(
            "12 Pods · Watching",
            toolTip: "The current resource query is explicit."
        ), for: .content)
        board.set(WorkspaceStatus(
            "47 resource kinds · discovery incomplete",
            severity: .warning,
            toolTip: "One API group is unavailable.",
            shortText: "discovery incomplete"
        ), for: .discovery)
        board.set(WorkspaceStatus(
            "Namespace list unavailable",
            severity: .error,
            toolTip: "Namespace access was denied."
        ), for: .namespace)

        let status = board.presented
        #expect(status.text == (
            "12 Pods · Watching · Namespace list unavailable · discovery incomplete"
        ))
        #expect(status.severity == .error)
        #expect(!status.busy)
        #expect(status.toolTip?.contains("The current resource query is explicit.") == true)
        #expect(status.toolTip?.contains("One API group is unavailable.") == true)
        #expect(status.toolTip?.contains("Namespace access was denied.") == true)
    }

    @Test("engine restart warning points to diagnostics without becoming a control")
    func engineRestartWarning() {
        var board = WorkspaceStatusBoard()
        board.set(WorkspaceStatus("12 Pods · Watching"), for: .content)
        board.set(EngineWorkspaceStatus.restarted, for: .engine)

        let status = board.presented
        #expect(status.text == "12 Pods · Watching · Engine restarted unexpectedly")
        #expect(status.severity == .warning)
        #expect(status.busy == false)
        #expect(status.toolTip?.contains("Window → Engine Diagnostics…") == true)
        #expect(status.toolTip?.contains("retained engine log") == true)
    }

    @Test("one fixed footer survives content swaps and ignores retired publishers")
    func persistentFooter() throws {
        let connection = ClusterConnectionActivityView()
        let host = WorkspaceRightPaneViewController(connectionActivityView: connection)
        let first = NSViewController()
        first.view = NSView()
        let second = NSViewController()
        second.view = NSView()
        host.setContent(first, initialStatus: WorkspaceStatus("First"))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.layoutIfNeeded()
        defer { window.contentViewController = nil }

        let statusBar = try #require(statusDescendants(of: host.view).first {
            $0.identifier?.rawValue == "workspace-status-bar"
        } as? NSStackView)
        let statusLabel = try #require(statusDescendants(of: host.view)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })
        let originalBar = statusBar
        let originalWindowFrame = window.frame

        host.setContent(second, initialStatus: WorkspaceStatus("Second"))
        host.updateContentStatus(WorkspaceStatus("Retired update"), from: first)
        #expect(statusLabel.stringValue == "Second")
        #expect(host.activeContentController === second)
        #expect(statusDescendants(of: host.view).contains { $0 === originalBar })
        #expect(statusDescendants(of: host.view).contains { $0 === connection })

        host.setSupplementalStatus(EngineWorkspaceStatus.restarted, for: .engine)
        #expect(statusLabel.stringValue == "Second · Engine restarted unexpectedly")
        #expect(statusLabel.accessibilityHelp()?.contains("Engine Diagnostics…") == true)
        host.setSupplementalStatus(nil, for: .engine)

        host.updateContentStatus(WorkspaceStatus(
            String(repeating: "long status ", count: 2_000),
            severity: .warning,
            busy: true,
            toolTip: "Complete long status"
        ), from: second)
        host.view.layoutSubtreeIfNeeded()
        #expect(statusLabel.maximumNumberOfLines == 1)
        #expect(statusLabel.lineBreakMode == NSLineBreakMode.byTruncatingTail)
        #expect(statusLabel.toolTip == "Complete long status")
        #expect(abs(statusBar.frame.height - 24) < 0.5)
        #expect(window.frame == originalWindowFrame)
    }
}
}

@MainActor
private func statusDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(statusDescendants(of:))
}
