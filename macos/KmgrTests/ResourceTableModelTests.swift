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
