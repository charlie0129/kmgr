import Testing
@testable import KmgrCore

@Test func selectedUIDsSurviveCellUpdatesAndArbitraryReordering() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    let c: ResourceUID = "c"
    let d: ResourceUID = "d"
    var model = ResourceTableModel(rows: [row(a), row(b), row(c), row(d)])
    model.selectExclusively(b)
    model.toggleSelection(of: d)

    let capture = model.captureUpdate(topVisibleUID: b, pixelOffsetFromTop: 7.5)
    let plan = model.apply(
        ResourceRowBatch(
            upserts: [row(b, status: "Pending"), row(d, status: "Succeeded")],
            visibleOrder: .replace([d, c, a, b])
        ),
        capture: capture
    )

    #expect(model.selectedUIDs == [b, d])
    #expect(model.rowByUID[b]?["status"]?.displayText == "Pending")
    #expect(model.orderedVisibleUIDs == [d, c, a, b])
    #expect(plan.selectedRowIndexes == [0, 3])
    #expect(plan.scrollRestoration == ScrollRestorationPlan(
        uid: b,
        rowIndex: 3,
        pixelOffsetFromTop: 7.5,
        precision: .exactIdentity
    ))
}

@Test func confirmedDeletionRemovesOnlyThatUIDFromSelection() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    let c: ResourceUID = "c"
    var model = ResourceTableModel(rows: [row(a), row(b), row(c)])
    model.selectExclusively(a)
    model.toggleSelection(of: b)

    model.apply(ResourceRowBatch(
        removedUIDs: [a],
        visibleOrder: .replace([c, b])
    ))

    #expect(model.selectedUIDs == [b])
    #expect(model.rowByUID[a] == nil)
    #expect(model.rowByUID[b] != nil)
    #expect(model.rowByUID[c] != nil)
    #expect(model.selectionAnchorUID == b)
}

@Test func sameNameReplacementWithNewUIDDoesNotInheritSelection() {
    let oldUID: ResourceUID = "old-uid"
    let replacementUID: ResourceUID = "new-uid"
    var model = ResourceTableModel(rows: [row(oldUID, name: "api")])
    model.selectExclusively(oldUID)

    model.apply(ResourceRowBatch(
        upserts: [row(replacementUID, name: "api")],
        removedUIDs: [oldUID],
        visibleOrder: .replace([replacementUID])
    ))

    #expect(model.selectedUIDs.isEmpty)
    #expect(model.selectionAnchorUID == nil)
    #expect(model.rowByUID[replacementUID]?.identity.name == "api")
    #expect(model.rowByUID[oldUID] == nil)
}

@Test func shiftAnchorStaysAttachedToUIDAfterReorder() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    let c: ResourceUID = "c"
    let d: ResourceUID = "d"
    var model = ResourceTableModel(rows: [row(a), row(b), row(c), row(d)])
    model.selectExclusively(b)

    model.apply(ResourceRowBatch(visibleOrder: .replace([d, b, a, c])))
    model.extendSelection(to: c)

    #expect(model.selectionAnchorUID == b)
    #expect(model.selectedUIDs == [b, a, c])
    #expect(model.selectedUIDs.contains(d) == false)
}

@Test func filterHidesSelectionWithoutDeletingItAndReportsCounts() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    let c: ResourceUID = "c"
    var model = ResourceTableModel(rows: [row(a), row(b), row(c)])
    model.selectExclusively(a)
    model.toggleSelection(of: b)

    // `b` is absent from the visible projection, but not confirmed removed.
    model.apply(ResourceRowBatch(visibleOrder: .replace([a, c])))

    #expect(model.selectedUIDs == [a, b])
    #expect(model.rowByUID[b] != nil)
    #expect(model.selectionCounts == SelectionCounts(selected: 2, visible: 1, hidden: 1))

    model.selectAllVisible()
    #expect(model.selectedUIDs == [a, b, c])
    #expect(model.selectionCounts == SelectionCounts(selected: 3, visible: 2, hidden: 1))
}

@Test func commandGesturePreservesHiddenSelectionAndTogglesVisibleProjection() {
    let hidden: ResourceUID = "hidden"
    let visibleA: ResourceUID = "visible-a"
    let visibleB: ResourceUID = "visible-b"
    var model = ResourceTableModel(rows: [row(hidden), row(visibleA), row(visibleB)])
    model.selectExclusively(hidden)
    model.toggleSelection(of: visibleA)
    model.apply(ResourceRowBatch(visibleOrder: .replace([visibleA, visibleB])))

    let removed = model.applySelectionGesture(
        clickedIndex: 0,
        modifiers: [.command]
    )
    #expect(removed)
    #expect(model.selectedUIDs == [hidden])

    let added = model.applySelectionGesture(
        clickedIndex: 1,
        modifiers: [.command]
    )
    #expect(added)

    #expect(model.selectedUIDs == [hidden, visibleB])
    #expect(model.selectionAnchorUID == visibleB)
    #expect(model.selectionCounts == SelectionCounts(selected: 2, visible: 1, hidden: 1))
}

@Test func shiftGestureKeepsUIDAnchorAfterReorderAndPreservesHiddenSelection() {
    let hidden: ResourceUID = "hidden"
    let anchor: ResourceUID = "anchor"
    let middle: ResourceUID = "middle"
    let target: ResourceUID = "target"
    var model = ResourceTableModel(rows: [row(hidden), row(anchor), row(middle), row(target)])
    model.selectExclusively(anchor)
    model.toggleSelection(of: hidden)
    model.apply(ResourceRowBatch(visibleOrder: .replace([target, middle, anchor])))
    #expect(model.selectionAnchorUID == hidden)

    // Establish the visible anchor explicitly, then reorder and reconcile the
    // AppKit range projection. Shift must not replace it with the target row.
    let establishedAnchor = model.applySelectionGesture(
        clickedIndex: 2,
        modifiers: [.command]
    )
    #expect(establishedAnchor)
    #expect(model.selectionAnchorUID == anchor)
    model.apply(ResourceRowBatch(visibleOrder: .replace([anchor, middle, target])))
    let extended = model.applySelectionGesture(
        clickedIndex: 2,
        modifiers: [.shift]
    )
    #expect(extended)

    #expect(model.selectedUIDs == [hidden, anchor, middle, target])
    #expect(model.selectionAnchorUID == anchor)
}

@Test func keyboardShiftExtensionGrowsAndContractsFromUIDAnchor() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    let anchor: ResourceUID = "anchor"
    let d: ResourceUID = "d"
    let e: ResourceUID = "e"
    var model = ResourceTableModel(rows: [row(a), row(b), row(anchor), row(d), row(e)])
    model.selectExclusively(anchor)

    #expect(model.selectionExtensionDestinationIndex(movingDown: true) == 3)
    let grewDown = model.applySelectionGesture(clickedIndex: 3, modifiers: [.shift])
    #expect(grewDown)
    #expect(model.selectedUIDs == [anchor, d])

    #expect(model.selectionExtensionDestinationIndex(movingDown: true) == 4)
    let grewDownAgain = model.applySelectionGesture(clickedIndex: 4, modifiers: [.shift])
    #expect(grewDownAgain)
    #expect(model.selectedUIDs == [anchor, d, e])

    #expect(model.selectionExtensionDestinationIndex(movingDown: false) == 3)
    let contractedUp = model.applySelectionGesture(clickedIndex: 3, modifiers: [.shift])
    #expect(contractedUp)
    #expect(model.selectedUIDs == [anchor, d])

    #expect(model.selectionExtensionDestinationIndex(movingDown: false) == 2)
    let collapsed = model.applySelectionGesture(clickedIndex: 2, modifiers: [.shift])
    #expect(collapsed)
    #expect(model.selectedUIDs == [anchor])

    #expect(model.selectionExtensionDestinationIndex(movingDown: false) == 1)
    let grewUp = model.applySelectionGesture(clickedIndex: 1, modifiers: [.shift])
    #expect(grewUp)
    #expect(model.selectedUIDs == [b, anchor])
}

@Test func replacingVisibleRowsDoesNotTreatOmissionAsDeletion() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    var model = ResourceTableModel(rows: [row(a), row(b)])
    model.selectExclusively(b)

    model.apply(ResourceRowBatch(visibleOrder: .replace([a])))
    model.apply(ResourceRowBatch(visibleOrder: .replace([b, a])))

    #expect(model.selectedUIDs == [b])
    #expect(model.selectionCounts.hidden == 0)
}

@Test func updateCaptureProtectsSelectionFromTransientTableFeedback() {
    let a: ResourceUID = "a"
    let b: ResourceUID = "b"
    var model = ResourceTableModel(rows: [row(a), row(b)])
    model.selectExclusively(b)
    let capture = model.captureUpdate(topVisibleUID: a)

    // Simulate NSTableView reporting a transient empty selection during a
    // reorder. Applying with the pre-update capture restores UID truth.
    model.replaceSelectionFromVisibleRows(indexes: [], anchorIndex: nil)
    model.apply(
        ResourceRowBatch(visibleOrder: .replace([b, a])),
        capture: capture
    )

    #expect(model.selectedUIDs == [b])
    #expect(model.selectionAnchorUID == b)
}

@Test func explicitNavigationClearsSelectionAfterReturningSavedUIDs() {
    let a: ResourceUID = "a"
    var model = ResourceTableModel(rows: [row(a)])
    model.selectExclusively(a)

    let saved = model.clearSelectionForNavigation()

    #expect(saved == [a])
    #expect(model.selectedUIDs.isEmpty)
    #expect(model.selectionAnchorUID == nil)
}

@Test func helperRecoveryRebindsCachedRowSessionWithoutChangingUIDSelection() {
    let uid: ResourceUID = "pod-uid"
    var model = ResourceTableModel(rows: [row(uid)])
    model.selectExclusively(uid)

    model.rebindClusterSessionID("session-after-restart")

    #expect(model.rowByUID[uid]?.identity.clusterSessionID == "session-after-restart")
    #expect(model.selectedUIDs == [uid])
    #expect(model.selectedIdentities.only?.uid == uid)
}

@Test func helperRecoveryBlocksNetworkActionsUntilFreshUIDSnapshotCompletes() {
    let cached: ResourceUID = "cached-uid"
    let fresh: ResourceUID = "fresh-uid"
    var trust = RecoveredResourceTrust()
    trust.requireValidation()

    #expect(!trust.permitsNetworkActions(for: [row(cached).identity]))
    trust.receiveDelta(upsertedUIDs: [cached], removedUIDs: [])
    #expect(!trust.permitsNetworkActions(for: [row(cached).identity]))

    trust.receiveSnapshot(uids: [cached], first: true, last: false)
    #expect(!trust.permitsNetworkActions(for: [row(cached).identity]))
    trust.receiveSnapshot(uids: [fresh], first: false, last: true)

    #expect(trust.permitsNetworkActions(for: [row(cached).identity]))
    #expect(trust.permitsNetworkActions(for: [row(fresh).identity]))
}

@Test func helperRecoveryNeverTrustsCachedUIDOmittedFromFreshSnapshot() {
    let omitted: ResourceUID = "old-uid"
    let authoritative: ResourceUID = "new-uid"
    var trust = RecoveredResourceTrust()
    trust.requireValidation()
    trust.receiveSnapshot(uids: [authoritative], first: true, last: true)

    #expect(!trust.permitsNetworkActions(for: [row(omitted).identity]))
    #expect(trust.permitsNetworkActions(for: [row(authoritative).identity]))

    trust.receiveDelta(upsertedUIDs: [], removedUIDs: [authoritative])
    #expect(!trust.permitsNetworkActions(for: [row(authoritative).identity]))
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
