import AppKit
import KmgrCore

/// The frame source is kept explicit at the application boundary. A restored
/// record reads its own raw frame; a fresh context may read the shared
/// exact-context bookmark; an unseen context starts from the global size.
enum WorkspaceWindowPlacementMode: Equatable {
    case fresh
    case restored
    case contextBookmark(frame: WorkspaceWindowFrame?)
}

/// Small, deterministic geometry helpers for workspace windows. AppKit's
/// raw frame supplies the historical rectangle; this type decides whether that
/// rectangle is reachable and chooses a bounded fallback on its display when
/// a display was disconnected or a new window would stack on an existing one.
enum WorkspaceWindowPlacement {
    static let defaultFrame = NSRect(
        x: 0,
        y: 0,
        width: 1_180,
        height: 760
    )
    static let minimumReachableWidth: CGFloat = 80
    static let minimumReachableHeight: CGFloat = 24
    static let adjacentGap: CGFloat = 16
    static let cascadeStep: CGFloat = 32
    static let maximumCascadeCandidates = 64

    static func visibleFrames() -> [NSRect] {
        NSScreen.screens.map(\.visibleFrame).filter(isUsableVisibleFrame)
    }

    static func resolve(
        defaultFrame: NSRect,
        savedFrame: NSRect?,
        minimumSize: NSSize,
        fallbackSize: NSSize?,
        visibleFrames: [NSRect],
        occupiedFrames: [NSRect] = [],
        avoidOccupiedSavedFrame: Bool = false,
        preferredFrame: NSRect? = nil
    ) -> NSRect {
        let screens = visibleFrames.filter(isUsableVisibleFrame)
        let occupied = occupiedFrames.filter(isUsableFrame)
        let preferredScreen = preferredScreen(
            savedFrame: savedFrame,
            preferredFrame: preferredFrame,
            defaultFrame: defaultFrame,
            visibleFrames: screens
        )
        if let savedFrame,
            isUsableFrame(savedFrame),
            savedFrame.width >= minimumSize.width,
            savedFrame.height >= minimumSize.height,
            isReachable(savedFrame, in: screens)
        {
            if !avoidOccupiedSavedFrame || !overlapsAny(savedFrame, occupied) {
                return savedFrame
            }
            if let adjacent = firstUnoccupiedAdjacentFrame(
                from: savedFrame,
                visibleFrame: preferredScreen,
                occupiedFrames: occupied
            ) {
                return adjacent
            }
            if let cascaded = firstCascadedFrame(
                from: savedFrame,
                visibleFrame: preferredScreen,
                occupiedFrames: occupied
            ) {
                return cascaded
            }
        }

        return fallbackFrame(
            defaultFrame: defaultFrame,
            minimumSize: minimumSize,
            requestedSize: fallbackSize,
            visibleFrames: screens,
            occupiedFrames: occupied,
            preferredScreen: preferredScreen
        )
    }

    static func isReachable(
        _ frame: NSRect,
        in visibleFrames: [NSRect]
    ) -> Bool {
        guard isUsableFrame(frame) else { return false }
        return visibleFrames.filter(isUsableVisibleFrame).contains { screen in
            let intersection = frame.intersection(screen)
            return intersection.width >= minimumReachableWidth
                && intersection.height >= minimumReachableHeight
        }
    }

    private static func fallbackFrame(
        defaultFrame: NSRect,
        minimumSize: NSSize,
        requestedSize: NSSize?,
        visibleFrames: [NSRect],
        occupiedFrames: [NSRect],
        preferredScreen: NSRect?
    ) -> NSRect {
        let baseFrame = isUsableFrame(defaultFrame) ? defaultFrame : Self.defaultFrame
        let size = fittedSize(
            requestedSize ?? baseFrame.size,
            minimumSize: minimumSize,
            visibleFrames: preferredScreen.map { [$0] } ?? visibleFrames
        )

        guard !visibleFrames.isEmpty else {
            return NSRect(origin: .zero, size: size)
        }

        if let preferredScreen,
            let preferredCandidate = bestFallbackCandidate(
                size: size,
                in: preferredScreen,
                occupiedFrames: occupiedFrames
            )
        {
            // A small cascade on the user's current/context display is more
            // useful than a perfectly disjoint window on a distant display.
            return preferredCandidate
        }

        var leastOccupied: (frame: NSRect, score: CGFloat)?
        for screen in visibleFrames {
            guard let candidate = bestFallbackCandidate(
                size: size,
                in: screen,
                occupiedFrames: occupiedFrames
            ) else { continue }
            let score = overlapScore(candidate, occupiedFrames)
            if score == 0 { return candidate }
            if leastOccupied == nil || score < leastOccupied!.score {
                leastOccupied = (candidate, score)
            }
        }
        return leastOccupied?.frame ?? centeredFrame(size: size, in: visibleFrames[0])
    }

    private static func firstUnoccupiedAdjacentFrame(
        from frame: NSRect,
        visibleFrame: NSRect?,
        occupiedFrames: [NSRect]
    ) -> NSRect? {
        guard let visibleFrame, frame.size.width <= visibleFrame.width,
            frame.size.height <= visibleFrame.height
        else { return nil }

        let base = clampedFrame(frame, size: frame.size, to: visibleFrame)
        let candidates = [
            NSRect(
                x: base.maxX + adjacentGap,
                y: base.minY,
                width: base.width,
                height: base.height
            ),
            NSRect(
                x: base.minX - base.width - adjacentGap,
                y: base.minY,
                width: base.width,
                height: base.height
            ),
            NSRect(
                x: base.minX,
                y: base.maxY + adjacentGap,
                width: base.width,
                height: base.height
            ),
            NSRect(
                x: base.minX,
                y: base.minY - base.height - adjacentGap,
                width: base.width,
                height: base.height
            ),
        ]
        for candidate in candidates {
            guard isContained(candidate, in: visibleFrame),
                !overlapsAny(candidate, occupiedFrames)
            else { continue }
            return candidate
        }
        return nil
    }

    private static func firstCascadedFrame(
        from frame: NSRect,
        visibleFrame: NSRect?,
        occupiedFrames: [NSRect]
    ) -> NSRect? {
        guard let visibleFrame else { return nil }
        let base = clampedFrame(frame, size: frame.size, to: visibleFrame)
        for offset in cascadeOffsets().dropFirst() {
            let candidate = clampedFrame(
                base.offsetBy(dx: offset.x, dy: offset.y),
                size: base.size,
                to: visibleFrame
            )
            guard candidate != base,
                !isExactStack(candidate, with: occupiedFrames)
            else { continue }
            // The first non-identical cascade is intentionally preferred. It
            // keeps a constrained display usable without sending the window
            // to another monitor just to eliminate a small overlap.
            return candidate
        }
        return isExactStack(base, with: occupiedFrames) ? nil : base
    }

    private static func bestFallbackCandidate(
        size: NSSize,
        in screen: NSRect,
        occupiedFrames: [NSRect]
    ) -> NSRect? {
        guard isUsableVisibleFrame(screen) else { return nil }
        let centered = centeredFrame(size: size, in: screen)
        var leastOccupied: (frame: NSRect, score: CGFloat)?
        var leastNonStacked: (frame: NSRect, score: CGFloat)?
        for offset in cascadeOffsets() {
            let candidate = clampedFrame(
                centered.offsetBy(dx: offset.x, dy: offset.y),
                size: size,
                to: screen
            )
            let score = overlapScore(candidate, occupiedFrames)
            if score == 0 { return candidate }
            if leastOccupied == nil || score < leastOccupied!.score {
                leastOccupied = (candidate, score)
            }
            if !isExactStack(candidate, with: occupiedFrames),
                leastNonStacked == nil || score < leastNonStacked!.score
            {
                leastNonStacked = (candidate, score)
            }
        }
        return leastNonStacked?.frame ?? leastOccupied?.frame
    }

    private static func preferredScreen(
        savedFrame: NSRect?,
        preferredFrame: NSRect?,
        defaultFrame: NSRect,
        visibleFrames: [NSRect]
    ) -> NSRect? {
        // A saved frame owns the display choice whenever it still touches a
        // visible display. An explicit source frame is the fallback for a
        // disconnected/invalid bookmark, keeping a new sibling beside the
        // window from which it was opened.
        if let screen = screenWithGreatestIntersection(
            savedFrame,
            in: visibleFrames
        ) {
            return screen
        }
        if let screen = screenWithGreatestIntersection(
            preferredFrame,
            in: visibleFrames
        ) {
            return screen
        }
        return screenWithGreatestIntersection(defaultFrame, in: visibleFrames)
    }

    private static func screenWithGreatestIntersection(
        _ frame: NSRect?,
        in visibleFrames: [NSRect]
    ) -> NSRect? {
        guard let frame, isUsableFrame(frame) else { return nil }
        var best: (screen: NSRect, area: CGFloat)?
        for screen in visibleFrames {
            let intersection = frame.intersection(screen)
            guard intersection.width > 0, intersection.height > 0 else {
                continue
            }
            let area = intersection.width * intersection.height
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }
        return best?.screen
    }

    private static func isContained(_ frame: NSRect, in container: NSRect) -> Bool {
        frame.minX >= container.minX
            && frame.maxX <= container.maxX
            && frame.minY >= container.minY
            && frame.maxY <= container.maxY
    }

    private static func isExactStack(_ frame: NSRect, with occupied: [NSRect]) -> Bool {
        occupied.contains { $0 == frame }
    }

    private static func fittedSize(
        _ requested: NSSize,
        minimumSize: NSSize,
        visibleFrames: [NSRect]
    ) -> NSSize {
        let minimumWidth = max(1, minimumSize.width)
        let minimumHeight = max(1, minimumSize.height)
        let requestedWidth = requested.width.isFinite && requested.width > 0
            ? requested.width
            : defaultFrame.width
        let requestedHeight = requested.height.isFinite && requested.height > 0
            ? requested.height
            : defaultFrame.height
        let maximumWidth = max(
            minimumWidth,
            visibleFrames.map(\.width).max() ?? requestedWidth
        )
        let maximumHeight = max(
            minimumHeight,
            visibleFrames.map(\.height).max() ?? requestedHeight
        )
        return NSSize(
            width: min(max(requestedWidth, minimumWidth), maximumWidth),
            height: min(max(requestedHeight, minimumHeight), maximumHeight)
        )
    }

    private static func centeredFrame(size: NSSize, in screen: NSRect) -> NSRect {
        NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func clampedFrame(
        _ frame: NSRect,
        size: NSSize,
        to screen: NSRect
    ) -> NSRect {
        let x: CGFloat
        if size.width <= screen.width {
            x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
        } else {
            x = screen.minX
        }
        let y: CGFloat
        if size.height <= screen.height {
            y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        } else {
            y = screen.minY
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func cascadeOffsets() -> [NSPoint] {
        var offsets: [NSPoint] = [NSPoint(x: 0, y: 0)]
        offsets.reserveCapacity(maximumCascadeCandidates)
        var distance = cascadeStep
        while offsets.count < maximumCascadeCandidates {
            offsets.append(NSPoint(x: distance, y: -distance))
            if offsets.count < maximumCascadeCandidates {
                offsets.append(NSPoint(x: -distance, y: -distance))
            }
            if offsets.count < maximumCascadeCandidates {
                offsets.append(NSPoint(x: distance, y: distance))
            }
            if offsets.count < maximumCascadeCandidates {
                offsets.append(NSPoint(x: -distance, y: distance))
            }
            distance += cascadeStep
        }
        return offsets
    }

    private static func overlapsAny(_ frame: NSRect, _ occupied: [NSRect]) -> Bool {
        occupied.contains { framesOverlap(frame, $0) }
    }

    private static func overlapScore(_ frame: NSRect, _ occupied: [NSRect]) -> CGFloat {
        occupied.reduce(into: CGFloat.zero) { score, other in
            let intersection = frame.intersection(other)
            if intersection.width > 0, intersection.height > 0 {
                score += intersection.width * intersection.height
            }
        }
    }

    private static func framesOverlap(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        return intersection.width > 0 && intersection.height > 0
    }

    private static func isUsableVisibleFrame(_ frame: NSRect) -> Bool {
        isUsableFrame(frame) && frame.width >= minimumReachableWidth
            && frame.height >= minimumReachableHeight
    }

    private static func isUsableFrame(_ frame: NSRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
