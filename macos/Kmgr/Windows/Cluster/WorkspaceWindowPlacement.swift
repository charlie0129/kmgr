import AppKit

/// The frame source is kept explicit at the application boundary. A restored
/// record reads its own AppKit frame key; a fresh context may read the shared
/// exact-context bookmark; an unseen context starts from the global size.
enum WorkspaceWindowPlacementMode: Equatable {
    case fresh
    case restored
    case contextBookmark(seedFrameAutosaveName: String)
}

/// Small, deterministic geometry helpers for workspace windows. AppKit's
/// named-frame API supplies the historical rectangle; this type decides
/// whether that rectangle is reachable and chooses a bounded visible fallback
/// when a display was disconnected or a new window would stack on an existing
/// one.
enum WorkspaceWindowPlacement {
    static let defaultFrame = NSRect(
        x: 0,
        y: 0,
        width: 1_180,
        height: 760
    )
    static let minimumReachableWidth: CGFloat = 80
    static let minimumReachableHeight: CGFloat = 24
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
        avoidOccupiedSavedFrame: Bool = false
    ) -> NSRect {
        let screens = visibleFrames.filter(isUsableVisibleFrame)
        let occupied = occupiedFrames.filter(isUsableFrame)
        if let savedFrame,
            isUsableFrame(savedFrame),
            savedFrame.width >= minimumSize.width,
            savedFrame.height >= minimumSize.height,
            isReachable(savedFrame, in: screens)
        {
            if !avoidOccupiedSavedFrame || !overlapsAny(savedFrame, occupied) {
                return savedFrame
            }
            if let offset = firstUnoccupiedOffsetFrame(
                from: savedFrame,
                visibleFrames: screens,
                occupiedFrames: occupied
            ) {
                return offset
            }
        }

        return fallbackFrame(
            defaultFrame: defaultFrame,
            minimumSize: minimumSize,
            requestedSize: fallbackSize,
            visibleFrames: screens,
            occupiedFrames: occupied
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
        occupiedFrames: [NSRect]
    ) -> NSRect {
        let baseFrame = isUsableFrame(defaultFrame) ? defaultFrame : Self.defaultFrame
        let size = fittedSize(
            requestedSize ?? baseFrame.size,
            minimumSize: minimumSize,
            visibleFrames: visibleFrames
        )

        guard !visibleFrames.isEmpty else {
            return NSRect(origin: .zero, size: size)
        }

        var leastOccupied: (frame: NSRect, score: CGFloat)?
        for screen in visibleFrames {
            let centered = centeredFrame(size: size, in: screen)
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
            }
        }
        return leastOccupied?.frame ?? centeredFrame(size: size, in: visibleFrames[0])
    }

    private static func firstUnoccupiedOffsetFrame(
        from frame: NSRect,
        visibleFrames: [NSRect],
        occupiedFrames: [NSRect]
    ) -> NSRect? {
        for offset in cascadeOffsets().dropFirst() {
            let candidate = frame.offsetBy(dx: offset.x, dy: offset.y)
            guard isReachable(candidate, in: visibleFrames),
                !overlapsAny(candidate, occupiedFrames)
            else { continue }
            return candidate
        }
        return nil
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
