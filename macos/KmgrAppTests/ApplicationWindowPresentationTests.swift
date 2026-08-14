import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@MainActor
@Suite("Application window presentation", .serialized)
struct ApplicationWindowPresentationTests {
    @Test("restoration setting is default-on and persists from Settings")
    func restorationSetting() throws {
        let suite = "kmgr-app-restoration-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(preferencesStore: store)
        let root = try #require(settings.window?.contentView)
        let restore = try #require(button(
            withAccessibilityIdentifier: "settings.restoreOpenClusterWindows",
            beneath: root
        ))

        #expect(restore.state == .on)
        restore.state = .off
        #expect(restore.state == .off)
        let apply = try #require(button(titled: "Apply", beneath: root))
        #expect(apply.isEnabled)
        apply.performClick(nil)

        #expect(!store.current.restoreOpenClusterWindows)
        #expect(!AppPreferencesStore(defaults: defaults).current.restoreOpenClusterWindows)
    }

    @Test("last workspace opens chooser only when the app remains running")
    func lastWorkspaceClosePolicy() {
        #expect(policy(independent: true).shouldPresentAfterWorkspaceClose)
        #expect(policy(forward: true).shouldPresentAfterWorkspaceClose)
        #expect(!policy().shouldPresentAfterWorkspaceClose)

        #expect(!policy(workspaces: 1, independent: true).shouldPresentAfterWorkspaceClose)
        #expect(!policy(chooser: true, independent: true).shouldPresentAfterWorkspaceClose)
        #expect(!policy(terminating: true, independent: true).shouldPresentAfterWorkspaceClose)
    }

    private func policy(
        terminating: Bool = false,
        workspaces: Int = 0,
        chooser: Bool = false,
        independent: Bool = false,
        forward: Bool = false
    ) -> ClusterManagerPresentationPolicy {
        ClusterManagerPresentationPolicy(
            isTerminating: terminating,
            remainingWorkspaceCount: workspaces,
            hasClusterManager: chooser,
            hasVisibleIndependentWindow: independent,
            hasActivePortForward: forward
        )
    }
}

@MainActor
private func button(
    withAccessibilityIdentifier identifier: String,
    beneath root: NSView
) -> NSButton? {
    descendants(of: root).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func button(titled title: String, beneath root: NSView) -> NSButton? {
    descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == title }
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}
