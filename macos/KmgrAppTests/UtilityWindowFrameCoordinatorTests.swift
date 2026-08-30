import AppKit
import Foundation
import KmgrCore
import KmgrTestSupport
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
private final class VisibleFrameBox {
    var frames: [NSRect] = []
}

@MainActor
@Suite("Utility window frame coordination", .serialized)
struct UtilityWindowFrameCoordinatorTests {
    private let visibleFrames = [
        NSRect(x: 0, y: 0, width: 1_600, height: 1_000),
        NSRect(x: -1_600, y: 0, width: 1_600, height: 1_000),
    ]

    @Test("restores a saved frame and captures a later user resize")
    func restoresAndCapturesFrame() async throws {
        let suite = "kmgr-utility-coordinator-round-trip-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = makeCoordinator(defaults: defaults)
        let firstWindow = makeWindow()
        let firstBinding = coordinator.makeBinding(
            for: firstWindow,
            kind: .logs,
            defaultFrame: firstWindow.frame,
            minimumSize: firstWindow.minSize
        )

        firstBinding.prepareForPresentation()
        firstBinding.finishPresentation()
        // Allow both short protection phases to complete before simulating a
        // later user move. The task is intentionally scheduled on the main
        // actor, so a small scheduling margin keeps this deterministic under
        // a loaded AppKit test process.
        try await Task.sleep(for: .milliseconds(100))
        let moved = firstWindow.frame.offsetBy(dx: 73, dy: -41)
        firstWindow.setFrame(moved, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: firstWindow
        )
        let captured = try #require(WorkspaceWindowFrame(appKitFrame: firstWindow.frame))
        #expect(coordinator.store.frame(for: .logs) == captured)

        coordinator.prepareForTermination()
        #expect(coordinator.flushPendingSave())
        firstBinding.invalidate()

        let reloadedStore = UtilityWindowFrameStore(defaults: defaults)
        let reloadedCoordinator = UtilityWindowFrameCoordinator(
            store: reloadedStore,
            visibleFramesProvider: { self.visibleFrames },
            initialProtectionDelay: .milliseconds(1),
            initialProtectionSettleDelay: .milliseconds(1)
        )
        let secondWindow = makeWindow()
        let secondBinding = reloadedCoordinator.makeBinding(
            for: secondWindow,
            kind: .logs,
            defaultFrame: secondWindow.frame,
            minimumSize: secondWindow.minSize
        )
        secondBinding.prepareForPresentation()
        #expect(secondWindow.frame == firstWindow.frame)
        secondBinding.invalidate()
    }

    @Test("cascades same-kind siblings without replacing the canonical frame")
    func cascadesWithoutOverwritingCanonicalFrame() throws {
        let suite = "kmgr-utility-coordinator-cascade-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 220, y: 320, width: 520, height: 340)
        #expect(store.set(saved, for: .details))
        #expect(store.flushPendingSave())
        let coordinator = makeCoordinator(defaults: defaults, store: store)

        let firstWindow = makeWindow()
        let firstBinding = coordinator.makeBinding(
            for: firstWindow,
            kind: .details,
            defaultFrame: firstWindow.frame,
            minimumSize: firstWindow.minSize
        )
        firstBinding.prepareForPresentation()
        let expectedSavedFrame = try #require(saved.appKitFrame)
        #expect(firstWindow.frame == expectedSavedFrame)

        let secondWindow = makeWindow()
        let secondBinding = coordinator.makeBinding(
            for: secondWindow,
            kind: .details,
            defaultFrame: secondWindow.frame,
            minimumSize: secondWindow.minSize
        )
        secondBinding.prepareForPresentation()

        #expect(secondWindow.frame != firstWindow.frame)
        #expect(!secondWindow.frame.intersects(firstWindow.frame))
        #expect(store.frame(for: .details) == saved)
        #expect(coordinator.ownsCanonical(firstBinding))
        #expect(!coordinator.ownsCanonical(secondBinding))

        secondBinding.endPresentation()
        firstBinding.endPresentation()
    }

    @Test("the canonical frame survives when the canonical owner closes first")
    func canonicalFrameSurvivesWhenCanonicalOwnerClosesFirst() throws {
        let suite = "kmgr-utility-coordinator-close-order-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 220, y: 320, width: 520, height: 340)
        #expect(store.set(saved, for: .details))
        let coordinator = makeCoordinator(defaults: defaults, store: store)

        let canonicalWindow = makeWindow()
        let canonicalBinding = coordinator.makeBinding(
            for: canonicalWindow,
            kind: .details,
            defaultFrame: canonicalWindow.frame,
            minimumSize: canonicalWindow.minSize
        )
        canonicalBinding.prepareForPresentation()

        let siblingWindow = makeWindow()
        let siblingBinding = coordinator.makeBinding(
            for: siblingWindow,
            kind: .details,
            defaultFrame: siblingWindow.frame,
            minimumSize: siblingWindow.minSize
        )
        siblingBinding.prepareForPresentation()

        // The canonical owner may close before the cascaded sibling. Its
        // frame must remain the durable last-user frame.
        canonicalBinding.endPresentation()
        #expect(store.frame(for: .details) == saved)
        #expect(!coordinator.ownsCanonical(siblingBinding))

        siblingBinding.endPresentation()
        #expect(store.frame(for: .details) == saved)

        let reopenedWindow = makeWindow()
        let reopenedBinding = coordinator.makeBinding(
            for: reopenedWindow,
            kind: .details,
            defaultFrame: reopenedWindow.frame,
            minimumSize: reopenedWindow.minSize
        )
        reopenedBinding.prepareForPresentation()
        #expect(reopenedWindow.frame == saved.appKitFrame)
        reopenedBinding.endPresentation()
    }

    @Test("the canonical frame survives when the sibling closes first")
    func canonicalFrameSurvivesWhenSiblingClosesFirst() throws {
        let suite = "kmgr-utility-coordinator-sibling-first-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 220, y: 320, width: 520, height: 340)
        #expect(store.set(saved, for: .details))
        let coordinator = makeCoordinator(defaults: defaults, store: store)

        let canonicalWindow = makeWindow()
        let canonicalBinding = coordinator.makeBinding(
            for: canonicalWindow,
            kind: .details,
            defaultFrame: canonicalWindow.frame,
            minimumSize: canonicalWindow.minSize
        )
        canonicalBinding.prepareForPresentation()

        let siblingWindow = makeWindow()
        let siblingBinding = coordinator.makeBinding(
            for: siblingWindow,
            kind: .details,
            defaultFrame: siblingWindow.frame,
            minimumSize: siblingWindow.minSize
        )
        siblingBinding.prepareForPresentation()

        siblingBinding.endPresentation()
        #expect(store.frame(for: .details) == saved)
        #expect(coordinator.ownsCanonical(canonicalBinding))

        canonicalBinding.endPresentation()
        #expect(store.frame(for: .details) == saved)

        let reopenedWindow = makeWindow()
        let reopenedBinding = coordinator.makeBinding(
            for: reopenedWindow,
            kind: .details,
            defaultFrame: reopenedWindow.frame,
            minimumSize: reopenedWindow.minSize
        )
        reopenedBinding.prepareForPresentation()
        #expect(reopenedWindow.frame == saved.appKitFrame)
        reopenedBinding.endPresentation()
    }

    @Test("an ordered-out sibling remains reserved for same-kind placement")
    func orderedOutSiblingRemainsReserved() throws {
        let suite = "kmgr-utility-coordinator-ordered-out-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 220, y: 320, width: 520, height: 340)
        #expect(store.set(saved, for: .yaml))
        let coordinator = makeCoordinator(defaults: defaults, store: store)

        let firstWindow = makeWindow()
        let firstBinding = coordinator.makeBinding(
            for: firstWindow,
            kind: .yaml,
            defaultFrame: firstWindow.frame,
            minimumSize: firstWindow.minSize
        )
        firstBinding.prepareForPresentation()
        firstWindow.orderOut(nil)

        let secondWindow = makeWindow()
        let secondBinding = coordinator.makeBinding(
            for: secondWindow,
            kind: .yaml,
            defaultFrame: secondWindow.frame,
            minimumSize: secondWindow.minSize
        )
        secondBinding.prepareForPresentation()

        #expect(secondWindow.frame != firstWindow.frame)
        #expect(!secondWindow.frame.intersects(firstWindow.frame))
        #expect(store.frame(for: .yaml) == saved)

        secondBinding.endPresentation()
        firstBinding.endPresentation()
    }

    @Test("an automatic re-presentation cascade cannot replace the canonical frame")
    func automaticRepresentationCascadeDoesNotReplaceCanonicalFrame() async throws {
        let suite = "kmgr-utility-coordinator-representation-cascade-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 220, y: 320, width: 520, height: 340)
        #expect(store.set(saved, for: .details))
        let coordinator = makeCoordinator(defaults: defaults, store: store)

        let canonicalWindow = makeWindow()
        let canonicalBinding = coordinator.makeBinding(
            for: canonicalWindow,
            kind: .details,
            defaultFrame: canonicalWindow.frame,
            minimumSize: canonicalWindow.minSize
        )
        canonicalBinding.prepareForPresentation()
        canonicalBinding.finishPresentation()

        let siblingWindow = makeWindow()
        let siblingBinding = coordinator.makeBinding(
            for: siblingWindow,
            kind: .details,
            defaultFrame: siblingWindow.frame,
            minimumSize: siblingWindow.minSize
        )
        siblingBinding.prepareForPresentation()
        siblingBinding.finishPresentation()
        try await Task.sleep(for: .milliseconds(100))

        // Model a same-kind window occupying the canonical frame without a
        // corresponding user notification. The owner being re-presented must
        // relinquish stale process-local ownership before its automatic
        // cascade is applied.
        siblingWindow.setFrame(try #require(saved.appKitFrame), display: false)
        canonicalWindow.orderOut(nil)
        canonicalBinding.prepareForPresentation()
        canonicalBinding.finishPresentation()
        try await Task.sleep(for: .milliseconds(100))

        #expect(canonicalWindow.frame != saved.appKitFrame)
        #expect(store.frame(for: .details) == saved)

        canonicalBinding.endPresentation()
        siblingBinding.endPresentation()
    }

    @Test("preserves a saved frame while display topology is unknown")
    func preservesSavedFrameWhenDisplaysAreUnknown() throws {
        let suite = "kmgr-utility-coordinator-unknown-displays-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: -840, y: 120, width: 520, height: 340)
        #expect(store.set(saved, for: .settings))
        let coordinator = UtilityWindowFrameCoordinator(
            store: store,
            visibleFramesProvider: { [] },
            initialProtectionDelay: .milliseconds(1),
            initialProtectionSettleDelay: .milliseconds(1)
        )
        let window = makeWindow()
        let binding = coordinator.makeBinding(
            for: window,
            kind: .settings,
            defaultFrame: window.frame,
            minimumSize: window.minSize
        )

        binding.prepareForPresentation()
        #expect(window.frame == saved.appKitFrame)
        #expect(store.frame(for: .settings) == saved)
        binding.endPresentation()
    }

    @Test("persists a fresh fallback while display topology is unknown")
    func persistsFreshFallbackWhenDisplaysAreUnknown() throws {
        let suite = "kmgr-utility-coordinator-fresh-unknown-displays-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let coordinator = UtilityWindowFrameCoordinator(
            store: store,
            visibleFramesProvider: { [] },
            initialProtectionDelay: .milliseconds(1),
            initialProtectionSettleDelay: .milliseconds(1)
        )
        let window = makeWindow()
        let binding = coordinator.makeBinding(
            for: window,
            kind: .terminal,
            defaultFrame: window.frame,
            minimumSize: window.minSize
        )

        binding.prepareForPresentation()
        let expected = try #require(WorkspaceWindowFrame(appKitFrame: window.frame))
        #expect(store.frame(for: .terminal) == expected)
        #expect(coordinator.ownsCanonical(binding))
        binding.endPresentation()
    }

    @Test("a late automatic notification at a cascaded target keeps the canonical frame")
    func lateAutomaticNotificationDoesNotReplaceCanonicalFrame() async throws {
        let suite = "kmgr-utility-coordinator-late-notification-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 220, y: 320, width: 520, height: 340)
        #expect(store.set(saved, for: .yaml))
        let coordinator = makeCoordinator(defaults: defaults, store: store)

        let firstWindow = makeWindow()
        let firstBinding = coordinator.makeBinding(
            for: firstWindow,
            kind: .yaml,
            defaultFrame: firstWindow.frame,
            minimumSize: firstWindow.minSize
        )
        firstBinding.prepareForPresentation()
        firstBinding.finishPresentation()

        let secondWindow = makeWindow()
        let secondBinding = coordinator.makeBinding(
            for: secondWindow,
            kind: .yaml,
            defaultFrame: secondWindow.frame,
            minimumSize: secondWindow.minSize
        )
        secondBinding.prepareForPresentation()
        secondBinding.finishPresentation()
        try await Task.sleep(for: .milliseconds(100))

        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: secondWindow
        )

        #expect(store.frame(for: .yaml) == saved)
        #expect(!coordinator.ownsCanonical(secondBinding))
        secondBinding.endPresentation()
        firstBinding.endPresentation()
    }

    @Test("repairs a saved frame after display topology becomes available")
    func repairsSavedFrameAfterDisplayTopologyAppears() async throws {
        let suite = "kmgr-utility-coordinator-late-displays-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let saved = WorkspaceWindowFrame(x: 3_000, y: 120, width: 520, height: 340)
        #expect(store.set(saved, for: .settings))
        let visibleFrameBox = VisibleFrameBox()
        let coordinator = UtilityWindowFrameCoordinator(
            store: store,
            visibleFramesProvider: { visibleFrameBox.frames },
            initialProtectionDelay: .milliseconds(1),
            initialProtectionSettleDelay: .milliseconds(1)
        )
        let window = makeWindow()
        let binding = coordinator.makeBinding(
            for: window,
            kind: .settings,
            defaultFrame: window.frame,
            minimumSize: window.minSize
        )

        binding.prepareForPresentation()
        #expect(window.frame == saved.appKitFrame)
        visibleFrameBox.frames = visibleFrames
        binding.finishPresentation()
        try await Task.sleep(for: .milliseconds(100))

        let repaired = try #require(WorkspaceWindowFrame(appKitFrame: window.frame))
        #expect(repaired != saved)
        #expect(WorkspaceWindowPlacement.isReachable(
            window.frame,
            in: visibleFrames
        ))
        #expect(store.frame(for: .settings) == repaired)
        binding.endPresentation()
    }

    @Test("reasserts an automatic initial move but accepts a live user resize")
    func protectsInitialPlacementAndAcceptsUserChange() async throws {
        let suite = "kmgr-utility-coordinator-protection-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = UtilityWindowFrameCoordinator(
            store: UtilityWindowFrameStore(
                defaults: defaults,
                persistenceDelay: .seconds(60)
            ),
            visibleFramesProvider: { self.visibleFrames },
            initialProtectionDelay: .milliseconds(5),
            initialProtectionSettleDelay: .milliseconds(5)
        )
        let window = makeWindow()
        let binding = coordinator.makeBinding(
            for: window,
            kind: .yaml,
            defaultFrame: window.frame,
            minimumSize: window.minSize
        )
        binding.prepareForPresentation()
        let chosen = window.frame
        binding.finishPresentation()

        let automaticMove = chosen.offsetBy(dx: 200, dy: 100)
        window.setFrame(automaticMove, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: window
        )
        // Include scheduling margin for the two asynchronous protection
        // phases, even though their configured delays are only 5 ms each.
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.frame == chosen)

        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        let userFrame = chosen.offsetBy(dx: 45, dy: -25)
        window.setFrame(userFrame, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didResizeNotification,
            object: window
        )
        #expect(window.frame == userFrame)
        #expect(coordinator.store.frame(for: .yaml)
            == WorkspaceWindowFrame(appKitFrame: userFrame))
        binding.invalidate()
    }

    @Test("moves an off-screen saved frame to a reachable display and persists the correction")
    func repairsOffScreenFrame() throws {
        let suite = "kmgr-utility-coordinator-offscreen-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let offScreen = WorkspaceWindowFrame(
            x: 30_000,
            y: 30_000,
            width: 520,
            height: 340
        )
        #expect(store.set(offScreen, for: .terminal))
        let coordinator = makeCoordinator(defaults: defaults, store: store)
        let window = makeWindow()
        let binding = coordinator.makeBinding(
            for: window,
            kind: .terminal,
            defaultFrame: window.frame,
            minimumSize: window.minSize
        )

        binding.prepareForPresentation()
        let repaired = try #require(WorkspaceWindowFrame(appKitFrame: window.frame))
        #expect(repaired != offScreen)
        #expect(repaired.width == offScreen.width)
        #expect(repaired.height == offScreen.height)
        #expect(WorkspaceWindowPlacement.isReachable(
            window.frame,
            in: visibleFrames
        ))
        #expect(store.frame(for: .terminal) == repaired)
        binding.invalidate()
    }

    @Test("termination captures the final canonical frame before the debounce expires")
    func terminationFlushesFinalFrame() async throws {
        let suite = "kmgr-utility-coordinator-termination-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let coordinator = makeCoordinator(defaults: defaults, store: store)
        let window = makeWindow()
        let binding = coordinator.makeBinding(
            for: window,
            kind: .engineDiagnostics,
            defaultFrame: window.frame,
            minimumSize: window.minSize
        )
        binding.prepareForPresentation()
        binding.finishPresentation()
        try await Task.sleep(for: .milliseconds(100))
        let finalFrame = window.frame.offsetBy(dx: 61, dy: 18)
        window.setFrame(finalFrame, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: window
        )

        coordinator.prepareForTermination()
        #expect(coordinator.flushPendingSave())
        binding.invalidate()
        let reloaded = UtilityWindowFrameStore(defaults: defaults)
        #expect(reloaded.frame(for: .engineDiagnostics)
            == WorkspaceWindowFrame(appKitFrame: finalFrame))
    }

    @Test("termination captures only the latest canonical owner's frame")
    func terminationUsesLatestCanonicalOwner() async throws {
        let suite = "kmgr-utility-coordinator-termination-owner-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let coordinator = makeCoordinator(defaults: defaults, store: store)
        let firstWindow = makeWindow()
        let firstBinding = coordinator.makeBinding(
            for: firstWindow,
            kind: .logs,
            defaultFrame: firstWindow.frame,
            minimumSize: firstWindow.minSize
        )
        firstBinding.prepareForPresentation()
        firstBinding.finishPresentation()

        let secondWindow = makeWindow()
        let secondBinding = coordinator.makeBinding(
            for: secondWindow,
            kind: .logs,
            defaultFrame: secondWindow.frame,
            minimumSize: secondWindow.minSize
        )
        secondBinding.prepareForPresentation()
        secondBinding.finishPresentation()
        try await Task.sleep(for: .milliseconds(100))

        let firstMoved = firstWindow.frame.offsetBy(dx: 41, dy: 17)
        firstWindow.setFrame(firstMoved, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: firstWindow
        )
        let secondMoved = secondWindow.frame.offsetBy(dx: -29, dy: 23)
        secondWindow.setFrame(secondMoved, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: secondWindow
        )
        let expected = try #require(WorkspaceWindowFrame(appKitFrame: secondMoved))
        #expect(store.frame(for: .logs) == expected)

        coordinator.prepareForTermination()
        #expect(coordinator.flushPendingSave())
        let reloaded = UtilityWindowFrameStore(defaults: defaults)
        #expect(reloaded.frame(for: .logs) == expected)

        firstBinding.invalidate()
        secondBinding.invalidate()
    }

    private func makeCoordinator(
        defaults: InMemoryUserDefaults,
        store: UtilityWindowFrameStore? = nil
    ) -> UtilityWindowFrameCoordinator {
        UtilityWindowFrameCoordinator(
            store: store ?? UtilityWindowFrameStore(
                defaults: defaults,
                persistenceDelay: .seconds(60)
            ),
            visibleFramesProvider: { self.visibleFrames },
            initialProtectionDelay: .milliseconds(1),
            initialProtectionSettleDelay: .milliseconds(1)
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 320, height: 220)
        window.setFrame(
            NSRect(x: 100, y: 180, width: 520, height: 340),
            display: false
        )
        return window
    }
}
}
