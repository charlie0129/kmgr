import AppKit
import Testing
@testable import Kmgr

@MainActor
@Suite("Workspace window placement", .serialized)
struct WorkspaceWindowPlacementTests {
    private let screens = [
        NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        NSRect(x: 0, y: 0, width: 1_600, height: 1_000),
    ]
    private let minimumSize = NSSize(width: 320, height: 220)

    @Test("a reachable saved frame keeps its multi-display origin")
    func reachableSavedFrameIsPreserved() {
        let saved = NSRect(x: -1_760, y: 140, width: 840, height: 620)
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: NSRect(x: 0, y: 0, width: 600, height: 400),
            savedFrame: saved,
            minimumSize: minimumSize,
            fallbackSize: NSSize(width: 900, height: 700),
            visibleFrames: screens
        )

        #expect(resolved == saved)
        #expect(WorkspaceWindowPlacement.isReachable(saved, in: screens))
    }

    @Test("an unknown display list preserves a usable saved frame")
    func unknownDisplaysPreserveSavedFrame() {
        let saved = NSRect(x: -840, y: 120, width: 840, height: 620)
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: .zero,
            savedFrame: saved,
            minimumSize: minimumSize,
            fallbackSize: NSSize(width: 900, height: 700),
            visibleFrames: []
        )

        #expect(resolved == saved)
    }

    @Test("an off-screen saved frame uses a visible bounded fallback")
    func offscreenSavedFrameFallsBack() {
        let offscreen = NSRect(x: 20_000, y: 20_000, width: 840, height: 620)
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: NSRect(x: 0, y: 0, width: 600, height: 400),
            savedFrame: offscreen,
            minimumSize: minimumSize,
            fallbackSize: NSSize(width: 900, height: 700),
            visibleFrames: screens
        )

        #expect(resolved != offscreen)
        #expect(WorkspaceWindowPlacement.isReachable(resolved, in: screens))
        #expect(resolved.size == NSSize(width: 900, height: 700))
    }

    @Test("a fresh fallback cascades away from an occupied window")
    func fallbackAvoidsOccupiedWindow() {
        let visible = [NSRect(x: 0, y: 0, width: 1_800, height: 1_200)]
        let size = NSSize(width: 520, height: 340)
        let first = WorkspaceWindowPlacement.resolve(
            defaultFrame: .zero,
            savedFrame: nil,
            minimumSize: minimumSize,
            fallbackSize: size,
            visibleFrames: visible
        )
        let second = WorkspaceWindowPlacement.resolve(
            defaultFrame: .zero,
            savedFrame: nil,
            minimumSize: minimumSize,
            fallbackSize: size,
            visibleFrames: visible,
            occupiedFrames: [first]
        )

        #expect(second != first)
        #expect(!second.intersects(first))
        #expect(WorkspaceWindowPlacement.isReachable(second, in: visible))
    }

    @Test("a bookmarked frame is offset when its source is still visible")
    func bookmarkedFrameAvoidsSourceWindow() {
        let saved = NSRect(x: 180, y: 620, width: 620, height: 420)
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: .zero,
            savedFrame: saved,
            minimumSize: minimumSize,
            fallbackSize: NSSize(width: 620, height: 420),
            visibleFrames: [NSRect(x: 0, y: 0, width: 1_600, height: 1_000)],
            occupiedFrames: [saved],
            avoidOccupiedSavedFrame: true
        )

        #expect(resolved != saved)
        #expect(!resolved.intersects(saved))
        #expect(WorkspaceWindowPlacement.isReachable(
            resolved,
            in: [NSRect(x: 0, y: 0, width: 1_600, height: 1_000)]
        ))
    }

    @Test("an occupied bookmark stays on its saved display when tiling is impossible")
    func occupiedBookmarkKeepsSavedDisplay() {
        let primary = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let secondary = NSRect(x: 1_600, y: 0, width: 1_600, height: 1_000)
        let saved = NSRect(x: 1_800, y: 100, width: 1_400, height: 800)
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: .zero,
            savedFrame: saved,
            minimumSize: minimumSize,
            fallbackSize: saved.size,
            visibleFrames: [primary, secondary],
            occupiedFrames: [saved],
            avoidOccupiedSavedFrame: true
        )

        #expect(resolved != saved)
        #expect(resolved.intersects(saved))
        #expect(resolved.minX >= secondary.minX)
        #expect(resolved.maxX <= secondary.maxX)
        #expect(resolved.minY >= secondary.minY)
        #expect(resolved.maxY <= secondary.maxY)
        #expect(WorkspaceWindowPlacement.isReachable(
            resolved,
            in: [primary, secondary]
        ))
    }

    @Test("an unavailable bookmark follows the current window's display")
    func unavailableBookmarkUsesPreferredDisplay() {
        let primary = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let secondary = NSRect(x: 1_600, y: 0, width: 1_600, height: 1_000)
        let unavailable = NSRect(x: 20_000, y: 20_000, width: 840, height: 620)
        let source = NSRect(x: 1_760, y: 140, width: 840, height: 620)
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: .zero,
            savedFrame: unavailable,
            minimumSize: minimumSize,
            fallbackSize: source.size,
            visibleFrames: [primary, secondary],
            preferredFrame: source
        )

        #expect(resolved.minX >= secondary.minX)
        #expect(resolved.maxX <= secondary.maxX)
        #expect(resolved.minY >= secondary.minY)
        #expect(resolved.maxY <= secondary.maxY)
        #expect(WorkspaceWindowPlacement.isReachable(
            resolved,
            in: [primary, secondary]
        ))
    }
}
