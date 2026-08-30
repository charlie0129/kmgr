import AppKit
import KmgrCore

/// Coordinates the process-wide geometry policy for independent utility
/// windows. The store owns only the canonical last frame for each kind; live
/// registrations are transient and exist solely to choose a useful cascade
/// when more than one window of the same kind is visible.
@MainActor
final class UtilityWindowFrameCoordinator {
    /// Controllers normally receive the application-owned coordinator. The
    /// shared fallback keeps independently constructed utility controllers in
    /// the same process-wide policy as well.
    static let shared = UtilityWindowFrameCoordinator()

    let store: UtilityWindowFrameStore

    private let visibleFramesProvider: @MainActor () -> [NSRect]
    private let initialProtectionDelay: Duration
    private let initialProtectionSettleDelay: Duration
    private var bindings: [UUID: UtilityWindowFrameBinding] = [:]
    private var canonicalOwners: [UtilityWindowKind: UUID] = [:]
    private var isPreparingForTermination = false

    init(
        store: UtilityWindowFrameStore = UtilityWindowFrameStore(),
        visibleFramesProvider: @escaping @MainActor () -> [NSRect] = {
            WorkspaceWindowPlacement.visibleFrames()
        },
        initialProtectionDelay: Duration = .milliseconds(500),
        initialProtectionSettleDelay: Duration = .milliseconds(250)
    ) {
        self.store = store
        self.visibleFramesProvider = visibleFramesProvider
        self.initialProtectionDelay = initialProtectionDelay
        self.initialProtectionSettleDelay = initialProtectionSettleDelay
    }

    func makeBinding(
        for window: NSWindow,
        kind: UtilityWindowKind,
        defaultFrame: NSRect,
        minimumSize: NSSize,
        preferredFrame: NSRect? = nil
    ) -> UtilityWindowFrameBinding {
        UtilityWindowFrameBinding(
            coordinator: self,
            window: window,
            kind: kind,
            defaultFrame: defaultFrame,
            minimumSize: minimumSize,
            preferredFrame: preferredFrame,
            initialProtectionDelay: initialProtectionDelay,
            initialProtectionSettleDelay: initialProtectionSettleDelay
        )
    }

    func visibleFrames() -> [NSRect] {
        visibleFramesProvider().filter { frame in
            frame.minX.isFinite && frame.minY.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
    }

    func occupiedFrames(
        for kind: UtilityWindowKind,
        excluding binding: UtilityWindowFrameBinding
    ) -> [NSRect] {
        pruneBindings()
        return bindings.values.compactMap { candidate in
            guard candidate !== binding,
                candidate.kind == kind,
                candidate.isPresentationActive,
                let window = candidate.window,
                candidate.reservesFrameForPlacement,
                let frame = WorkspaceWindowFrame(appKitFrame: window.frame)?.appKitFrame
            else { return nil }
            return frame
        }
    }

    func register(_ binding: UtilityWindowFrameBinding) {
        guard !isPreparingForTermination else { return }
        pruneBindings()
        bindings[binding.id] = binding
    }

    func unregister(_ binding: UtilityWindowFrameBinding) {
        bindings.removeValue(forKey: binding.id)
        if canonicalOwners[binding.kind] == binding.id {
            canonicalOwners.removeValue(forKey: binding.kind)
        }
    }

    /// Gives up process-local ownership without changing the durable frame.
    /// This is needed when an owner is being presented again but another
    /// same-kind window occupies the canonical rectangle and forces a cascade.
    func relinquishCanonical(_ binding: UtilityWindowFrameBinding) {
        guard canonicalOwners[binding.kind] == binding.id else { return }
        canonicalOwners.removeValue(forKey: binding.kind)
    }

    /// Records an authoritative frame change and remembers which live binding
    /// most recently supplied it. The owner is process-local metadata; the
    /// durable store intentionally contains only one bounded frame per kind.
    @discardableResult
    func record(
        _ frame: WorkspaceWindowFrame,
        from binding: UtilityWindowFrameBinding
    ) -> Bool {
        guard binding.isPresentationActive, !binding.isInvalidated else {
            return false
        }
        guard store.set(frame, for: binding.kind) else { return false }
        canonicalOwners[binding.kind] = binding.id
        return true
    }

    func claimCanonical(
        _ binding: UtilityWindowFrameBinding,
        for frame: WorkspaceWindowFrame
    ) {
        guard binding.isPresentationActive, !binding.isInvalidated,
            store.frame(for: binding.kind) == frame
        else { return }
        canonicalOwners[binding.kind] = binding.id
    }

    func ownsCanonical(_ binding: UtilityWindowFrameBinding) -> Bool {
        canonicalOwners[binding.kind] == binding.id
    }

    /// Called by the application before asynchronous shutdown. Each active
    /// binding gets one final opportunity to capture a genuine user frame;
    /// the store is flushed separately by the application.
    func prepareForTermination() {
        guard !isPreparingForTermination else { return }
        isPreparingForTermination = true
        for binding in Array(bindings.values) {
            binding.prepareForTermination()
        }
    }

    @discardableResult
    func flushPendingSave() -> Bool {
        store.flushPendingSave()
    }

    private func pruneBindings() {
        bindings = bindings.filter { _, binding in
            binding.window != nil && !binding.isInvalidated
        }
        let liveIDs = Set(bindings.keys)
        canonicalOwners = canonicalOwners.filter { _, ownerID in
            liveIDs.contains(ownerID)
        }
    }
}

/// A controller-owned binding that applies a utility frame before first
/// presentation, protects it from AppKit's initial Space/activation moves,
/// and records subsequent user moves/resizes in the shared store.
@MainActor
final class UtilityWindowFrameBinding: NSObject {
    weak var window: NSWindow?
    weak var coordinator: UtilityWindowFrameCoordinator?

    let id: UUID
    let kind: UtilityWindowKind

    private let defaultFrame: NSRect
    private let minimumSize: NSSize
    private let preferredFrame: NSRect?
    private let initialProtectionDelay: Duration
    private let initialProtectionSettleDelay: Duration
    private var initialTargetFrame: NSRect?
    private var initialPlacementShouldPersist = false
    private var initialPlacementIsCascaded = false
    private var initialPlacementPending = false
    private var initialProtectionPending = false
    private var userChangedInitialPlacement = false
    private var isApplyingInitialFrame = false
    private var protectionTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0
    private var terminationPrepared = false
    private(set) var isPresentationActive = false
    private(set) var isInvalidated = false

    var reservesFrameForPlacement: Bool {
        // A window that has been ordered out or miniaturized is still an open
        // sibling. Reserve its frame so a newly opened same-kind window does
        // not later collide with it when it is shown again.
        isPresentationActive && window != nil
    }

    init(
        coordinator: UtilityWindowFrameCoordinator,
        window: NSWindow,
        kind: UtilityWindowKind,
        defaultFrame: NSRect,
        minimumSize: NSSize,
        preferredFrame: NSRect?,
        initialProtectionDelay: Duration,
        initialProtectionSettleDelay: Duration
    ) {
        self.id = UUID()
        self.coordinator = coordinator
        self.window = window
        self.kind = kind
        self.defaultFrame = defaultFrame
        self.minimumSize = minimumSize
        self.preferredFrame = preferredFrame
        self.initialProtectionDelay = initialProtectionDelay
        self.initialProtectionSettleDelay = initialProtectionSettleDelay
        super.init()
        installObservers(for: window)
    }

    deinit {
        protectionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// Applies the saved or resolved frame and marks this binding as an
    /// occupied live window for sibling placement. Call before `showWindow`.
    func prepareForPresentation() {
        guard !isInvalidated, !terminationPrepared, let window else { return }
        if isPresentationActive {
            // `showWindow` is also used to bring an ordered-out or
            // miniaturized utility back. Re-resolve that presentation so a
            // disconnected display or a newly visible sibling cannot leave
            // it stacked at an obsolete frame. Repeated calls while AppKit is
            // still settling the first presentation remain idempotent.
            guard !initialPlacementPending, !initialProtectionPending,
                !window.isVisible || window.isMiniaturized
            else { return }
            protectionTask?.cancel()
            protectionTask = nil
        } else {
            isPresentationActive = true
        }
        coordinator?.register(self)

        let visibleFrames = coordinator?.visibleFrames() ?? []
        let savedFrame = coordinator?.store.frame(for: kind)?.appKitFrame
        let savedFrameIsUsable = savedFrame.map {
            $0.width >= minimumSize.width
                && $0.height >= minimumSize.height
                // An empty screen list can occur during early app startup.
                // Preserve a valid saved frame until display topology is
                // available instead of replacing it with an origin fallback.
                && (visibleFrames.isEmpty
                    || WorkspaceWindowPlacement.isReachable($0, in: visibleFrames))
        } ?? false
        let occupiedFrames = coordinator?.occupiedFrames(
            for: kind,
            excluding: self
        ) ?? []
        let resolved = WorkspaceWindowPlacement.resolve(
            defaultFrame: defaultFrame,
            savedFrame: savedFrame,
            minimumSize: minimumSize,
            // A disconnected display should change only the placement when
            // the saved dimensions are still usable. If the saved frame is
            // too large for the current display, the placement helper fits
            // those dimensions to the available screen.
            fallbackSize: savedFrame?.size ?? defaultFrame.size,
            visibleFrames: visibleFrames,
            occupiedFrames: occupiedFrames,
            avoidOccupiedSavedFrame: true,
            preferredFrame: preferredFrame
        )
        let unoccupiedResolution = WorkspaceWindowPlacement.resolve(
            defaultFrame: defaultFrame,
            savedFrame: savedFrame,
            minimumSize: minimumSize,
            fallbackSize: savedFrame?.size ?? defaultFrame.size,
            visibleFrames: visibleFrames,
            occupiedFrames: [],
            avoidOccupiedSavedFrame: false,
            preferredFrame: preferredFrame
        )

        // Set every initial-placement guard before touching AppKit. `setFrame`
        // can synchronously emit didMove/didResize, and those callbacks must
        // never make a cascaded sibling the canonical saved frame.
        initialPlacementIsCascaded = !occupiedFrames.isEmpty
            && (resolved != unoccupiedResolution
                || framesOverlap(resolved, occupiedFrames))
        if initialPlacementIsCascaded {
            coordinator?.relinquishCanonical(self)
        }
        initialPlacementShouldPersist = !savedFrameIsUsable
            && !initialPlacementIsCascaded
        initialPlacementPending = true
        initialProtectionPending = false
        userChangedInitialPlacement = false
        presentationGeneration &+= 1
        initialTargetFrame = resolved
        isApplyingInitialFrame = true
        applyFrame(resolved, to: window)
        isApplyingInitialFrame = false
        initialTargetFrame = window.frame

        // If the saved frame was disconnected or otherwise unusable, make the
        // correction durable immediately. A valid saved frame that was
        // cascaded around a sibling remains the canonical frame in the store.
        if initialPlacementShouldPersist,
            let corrected = WorkspaceWindowFrame(appKitFrame: window.frame)
        {
            _ = coordinator?.record(corrected, from: self)
        } else if let savedFrame,
            let actual = WorkspaceWindowFrame(appKitFrame: window.frame),
            savedFrameIsUsable,
            actual.appKitFrame == savedFrame,
            !occupiedFrames.contains(where: {
                let intersection = savedFrame.intersection($0)
                return intersection.width > 0 && intersection.height > 0
            })
        {
            coordinator?.claimCanonical(self, for: actual)
        }
    }

    /// Completes the pre-presentation phase after AppKit has ordered the
    /// window. A short protection interval prevents activation/Space changes
    /// from replacing the chosen frame before the window server settles.
    func finishPresentation() {
        guard isPresentationActive, initialPlacementPending,
            !terminationPrepared
        else { return }
        protectionTask?.cancel()
        initialProtectionPending = true
        let generation = presentationGeneration
        let protectionDelay = initialProtectionDelay
        let settleDelay = initialProtectionSettleDelay
        protectionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: protectionDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                self.presentationGeneration == generation,
                self.isPresentationActive,
                !self.terminationPrepared
            else { return }
            self.reassertInitialFrameIfNeeded()

            do {
                try await Task.sleep(for: settleDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                self.presentationGeneration == generation,
                self.isPresentationActive,
                !self.terminationPrepared
            else { return }
            self.reassertInitialFrameIfNeeded()
            self.initialProtectionPending = false
            self.initialPlacementPending = false
            self.protectionTask = nil
            if self.mayPersistCurrentFrame {
                self.persistCurrentFrame()
            }
        }
    }

    /// Removes this window from sibling placement while preserving its last
    /// frame for the next presentation. The binding itself remains reusable
    /// for singleton controllers such as Settings and Port Forwards.
    func endPresentation() {
        guard isPresentationActive else { return }
        captureFinalFrame()
        protectionTask?.cancel()
        protectionTask = nil
        initialProtectionPending = false
        initialPlacementPending = false
        initialTargetFrame = nil
        isApplyingInitialFrame = false
        initialPlacementIsCascaded = false
        presentationGeneration &+= 1
        isPresentationActive = false
        coordinator?.unregister(self)
    }

    /// Disarms callbacks during application shutdown but captures a frame if
    /// the user changed it during the initial protection interval.
    func prepareForTermination() {
        guard !terminationPrepared else { return }
        captureFinalFrame()
        terminationPrepared = true
        protectionTask?.cancel()
        protectionTask = nil
        initialProtectionPending = false
        initialPlacementPending = false
        isApplyingInitialFrame = false
    }

    func invalidate() {
        guard !isInvalidated else { return }
        endPresentation()
        isInvalidated = true
        protectionTask?.cancel()
        protectionTask = nil
        coordinator?.unregister(self)
        coordinator = nil
        window = nil
    }

    private func installObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowWillMove(_:)),
            name: NSWindow.willMoveNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowWillStartLiveResize(_:)),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidEndLiveResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func windowWillMove(_ notification: Notification) {
        guard isPresentationActive, !terminationPrepared,
            !isApplyingInitialFrame,
            initialPlacementPending || initialProtectionPending,
            isCurrentEventLikelyUserGesture
        else { return }
        markUserChangedInitialPlacement()
    }

    @objc private func windowDidMove(_ notification: Notification) {
        handleFrameChange()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        handleFrameChange()
    }

    @objc private func windowWillStartLiveResize(_ notification: Notification) {
        guard isPresentationActive, !terminationPrepared,
            !isApplyingInitialFrame,
            initialPlacementPending || initialProtectionPending
        else { return }
        markUserChangedInitialPlacement()
    }

    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        guard isPresentationActive, !terminationPrepared,
            !isApplyingInitialFrame
        else { return }
        if initialPlacementPending || initialProtectionPending {
            markUserChangedInitialPlacement()
        }
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        handleFrameChange()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        endPresentation()
    }

    private func handleFrameChange() {
        guard isPresentationActive, !terminationPrepared,
            !isApplyingInitialFrame
        else { return }
        if initialPlacementPending || initialProtectionPending {
            if isCurrentEventLikelyUserGesture {
                markUserChangedInitialPlacement()
            }
            return
        }
        if !userChangedInitialPlacement,
            let initialTargetFrame,
            window?.frame == initialTargetFrame,
            !isCurrentEventLikelyUserGesture
        {
            // AppKit can deliver a queued automatic move/resize notification
            // after the protection task has finished. The frame is still the
            // one we deliberately applied, so it is not evidence of a user
            // change; in particular, do not make an automatic cascade
            // canonical. A real gesture is marked by willMove/live-resize
            // before this callback and therefore bypasses this guard.
            return
        }
        // Once a window has completed its protected initial placement, a
        // subsequent frame notification is the user's move/resize signal. A
        // cascaded sibling may then become the new canonical frame, but its
        // automatic initial cascade never can.
        userChangedInitialPlacement = true
        initialPlacementIsCascaded = false
        persistCurrentFrame()
    }

    private func reassertInitialFrameIfNeeded() {
        guard !userChangedInitialPlacement, let window,
            var target = initialTargetFrame
        else { return }

        let visibleFrames = coordinator?.visibleFrames() ?? []
        if !WorkspaceWindowPlacement.isReachable(target, in: visibleFrames),
            !visibleFrames.isEmpty
        {
            let occupiedFrames = coordinator?.occupiedFrames(
                for: kind,
                excluding: self
            ) ?? []
            let canPersistCorrection = !initialPlacementIsCascaded
                && (initialPlacementShouldPersist
                    || coordinator?.ownsCanonical(self) == true
                    || occupiedFrames.isEmpty)
            target = WorkspaceWindowPlacement.resolve(
                defaultFrame: defaultFrame,
                savedFrame: nil,
                minimumSize: minimumSize,
                fallbackSize: target.size,
                visibleFrames: visibleFrames,
                occupiedFrames: occupiedFrames,
                avoidOccupiedSavedFrame: false,
                preferredFrame: preferredFrame
            )
            initialPlacementShouldPersist = canPersistCorrection
            isApplyingInitialFrame = true
            applyFrame(target, to: window)
            isApplyingInitialFrame = false
            initialTargetFrame = window.frame
            if canPersistCorrection,
                let corrected = WorkspaceWindowFrame(appKitFrame: window.frame)
            {
                _ = coordinator?.record(corrected, from: self)
            }
            return
        }

        if window.frame != target {
            isApplyingInitialFrame = true
            applyFrame(target, to: window)
            isApplyingInitialFrame = false
            initialTargetFrame = window.frame
        }
    }

    private func applyFrame(_ frame: NSRect, to window: NSWindow) {
        window.setFrame(frame, display: false)
    }

    private func persistCurrentFrame() {
        guard mayPersistCurrentFrame,
            !isInvalidated, !terminationPrepared,
            let frame = window?.frame,
            let portable = WorkspaceWindowFrame(appKitFrame: frame)
        else { return }
        _ = coordinator?.record(portable, from: self)
    }

    private func markUserChangedInitialPlacement() {
        guard isPresentationActive, !terminationPrepared,
            !isApplyingInitialFrame
        else { return }
        userChangedInitialPlacement = true
        initialPlacementShouldPersist = true
        initialPlacementIsCascaded = false
        initialPlacementPending = false
        initialProtectionPending = false
        protectionTask?.cancel()
        protectionTask = nil
        persistCurrentFrame()
    }

    private var mayPersistCurrentFrame: Bool {
        !initialPlacementIsCascaded
            && (initialPlacementShouldPersist
                || userChangedInitialPlacement
                || coordinator?.ownsCanonical(self) == true)
    }

    private func framesOverlap(_ frame: NSRect, _ occupiedFrames: [NSRect]) -> Bool {
        occupiedFrames.contains { occupied in
            let intersection = frame.intersection(occupied)
            return intersection.width > 0 && intersection.height > 0
        }
    }

    private func captureFinalFrame() {
        guard isPresentationActive, !isInvalidated else { return }
        if (initialPlacementPending || initialProtectionPending)
            && !userChangedInitialPlacement
        {
            // A termination or close can arrive before the protection task's
            // first turn. Reassert the chosen target before deciding whether
            // this binding may update the canonical frame.
            reassertInitialFrameIfNeeded()
        }
        // Only the current canonical owner may perform a final capture. A
        // previously canonical sibling can still have a valid, older frame in
        // memory after another sibling was moved; letting both capture here
        // would make termination order decide which frame survives.
        guard !initialPlacementIsCascaded,
            coordinator?.ownsCanonical(self) == true
        else { return }
        persistCurrentFrame()
    }

    private var isCurrentEventLikelyUserGesture: Bool {
        if window?.inLiveResize == true || NSEvent.pressedMouseButtons != 0 {
            return true
        }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged,
            .rightMouseDown, .rightMouseDragged,
            .otherMouseDown, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}
