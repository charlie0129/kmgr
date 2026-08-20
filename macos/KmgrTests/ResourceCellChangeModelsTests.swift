import Foundation
import Testing
@testable import KmgrCore

@Test func resourceCellDetectorNeedsAnExistingMatchingUID() {
    let detector = ResourceRowChangeDetector(columnDefinitions: [])
    let incoming = changeRow(uid: "new", name: "api", cells: [
        changeCell("status", "Running"),
    ])

    #expect(detector.changes(from: nil, to: incoming).isEmpty)

    let sameNameOldUID = changeRow(uid: "old", name: "api", cells: [
        changeCell("status", "Pending"),
    ])
    #expect(detector.changes(from: sameNameOldUID, to: incoming).isEmpty)
}

@Test func resourceCellDetectorHotPathUsesDisplayTextOnly() {
    let uid: ResourceUID = "pod-1"
    let detector = ResourceRowChangeDetector(columnDefinitions: [])
    let previous = changeRow(uid: uid, cells: [
        Cell(
            columnID: "status",
            displayText: "Running",
            typedValue: .string("old typed value"),
            tooltip: "old tooltip",
            severity: .normal
        ),
        changeCell("cpu", "100m", typedValue: .number(0.1)),
        changeCell("node", "node-a"),
    ])
    let incoming = changeRow(uid: uid, cells: [
        Cell(
            columnID: "status",
            displayText: "Running",
            typedValue: .string("new typed value"),
            tooltip: "new tooltip",
            severity: .critical
        ),
        changeCell("cpu", "120m", typedValue: .number(0.12)),
        changeCell("node", "node-b"),
    ])

    #expect(detector.changes(from: previous, to: incoming) == [
        ResourceCellChange(
            address: ResourceCellAddress(uid: uid, columnID: "cpu")
        ),
        ResourceCellChange(
            address: ResourceCellAddress(uid: uid, columnID: "node")
        ),
    ])
}

@Test func resourceCellDetectorFallbackMatchesReorderedColumnsByID() {
    let uid: ResourceUID = "pod-1"
    let detector = ResourceRowChangeDetector(columnDefinitions: [])
    let previous = changeRow(uid: uid, cells: [
        changeCell("name", "api"),
        changeCell("status", "Pending"),
        changeCell("node", "node-a"),
    ])
    let incoming = changeRow(uid: uid, cells: [
        changeCell("node", "node-b"),
        changeCell("new-column", "new value"),
        changeCell("name", "api"),
    ])

    #expect(detector.changes(from: previous, to: incoming) == [
        ResourceCellChange(
            address: ResourceCellAddress(uid: uid, columnID: "node")
        ),
    ])
}

@Test func resourceCellDetectorRejectsAmbiguousFallbackRows() {
    let detector = ResourceRowChangeDetector(columnDefinitions: [])
    let previousDuplicate = changeRow(uid: "pod-1", cells: [
        changeCell("status", "Pending"),
        changeCell("status", "Running"),
    ])
    let incoming = changeRow(uid: "pod-1", cells: [
        changeCell("status", "Failed"),
    ])
    #expect(detector.changes(from: previousDuplicate, to: incoming).isEmpty)

    let previous = changeRow(uid: "pod-1", cells: [
        changeCell("name", "api"),
        changeCell("status", "Pending"),
    ])
    let incomingDuplicate = changeRow(uid: "pod-1", cells: [
        changeCell("status", "Running"),
        changeCell("name", "api"),
        changeCell("status", "Failed"),
    ])
    #expect(detector.changes(from: previous, to: incomingDuplicate).isEmpty)
}

@Test func resourceCellDetectorBoundsOnlyItsReorderFallback() {
    let detector = ResourceRowChangeDetector(columnDefinitions: [])
    let columnCount = ResourceRowChangeDetector.maximumFallbackColumnCount + 1
    let originalCells = (0..<columnCount).map {
        changeCell("column-\($0)", "value-\($0)")
    }
    var sameOrderCells = originalCells
    sameOrderCells[columnCount - 1].displayText = "changed"

    let hotPathChanges = detector.changes(
        from: changeRow(uid: "wide", cells: originalCells),
        to: changeRow(uid: "wide", cells: sameOrderCells)
    )
    #expect(hotPathChanges == [ResourceCellChange(
        address: ResourceCellAddress(
            uid: "wide",
            columnID: "column-\(columnCount - 1)"
        )
    )])

    let reorderedCells = Array(sameOrderCells.reversed())
    #expect(detector.changes(
        from: changeRow(uid: "wide", cells: originalCells),
        to: changeRow(uid: "wide", cells: reorderedCells)
    ).isEmpty)
}

@Test func resourceCellDetectorMarksOnlyExactBuiltinRestartIncreasesAsWarning() {
    let restartDefinition = changeDefinition(
        id: "restart-total",
        source: .builtin,
        value: "restarts"
    )
    let detector = ResourceRowChangeDetector(columnDefinitions: [restartDefinition])

    let numberIncrease = detector.changes(
        from: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "1", typedValue: .number(1)),
        ]),
        to: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "2", typedValue: .number(2)),
        ])
    )
    #expect(numberIncrease == [ResourceCellChange(
        address: ResourceCellAddress(uid: "pod", columnID: "restart-total"),
        emphasis: .warning
    )])

    let mixedTypedIncrease = detector.changes(
        from: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "2", typedValue: .integer(2)),
        ]),
        to: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "3", typedValue: .number(3)),
        ])
    )
    #expect(mixedTypedIncrease.first?.emphasis == .warning)

    let unchangedDisplay = detector.changes(
        from: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "3", typedValue: .integer(3)),
        ]),
        to: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "3", typedValue: .integer(4)),
        ])
    )
    #expect(unchangedDisplay.isEmpty)
}

@Test func podStateTransitionsUseProjectedSemanticSeverity() {
    let detector = ResourceRowChangeDetector(columnDefinitions: [
        changeDefinition(id: "ready", source: .builtin, value: "ready"),
        changeDefinition(id: "status", source: .builtin, value: "status"),
    ])
    let previous = changeRow(uid: "pod", cells: [
        changeCell("ready", "1 / 1", severity: .normal),
        changeCell("status", "Running", severity: .normal),
    ])

    let runningNotReady = detector.changes(
        from: previous,
        to: changeRow(uid: "pod", cells: [
            changeCell("ready", "0 / 1", severity: .critical),
            // A severity-only transition must still flash Status so its
            // unchanged "Running" text cannot hide a readiness regression.
            changeCell("status", "Running", severity: .critical),
        ])
    )
    #expect(runningNotReady == [
        ResourceCellChange(
            address: ResourceCellAddress(uid: "pod", columnID: "ready"),
            emphasis: .regression
        ),
        ResourceCellChange(
            address: ResourceCellAddress(uid: "pod", columnID: "status"),
            emphasis: .regression
        ),
    ])

    let pending = detector.changes(
        from: previous,
        to: changeRow(uid: "pod", cells: [
            changeCell("ready", "0 / 1", severity: .warning),
            changeCell("status", "Pending", severity: .warning),
        ])
    )
    #expect(pending.allSatisfy { $0.emphasis == .warning })
}

@Test func nonPodSeverityOnlyChangesDoNotCreatePodSemanticHighlights() {
    let detector = ResourceRowChangeDetector(columnDefinitions: [
        changeDefinition(id: "status", source: .builtin, value: "status"),
    ])
    var previous = changeRow(uid: "node", cells: [
        changeCell("status", "Ready", severity: .normal),
    ])
    previous.identity.resource = "nodes"
    var incoming = previous
    incoming.cells[0].severity = .critical

    #expect(detector.changes(from: previous, to: incoming).isEmpty)
}

@Test(arguments: [
    (CellTypedValue.integer(3), CellTypedValue.integer(2)),
    (.number(1.5), .number(2.5)),
    (.number(-1), .number(0)),
    (.number(.infinity), .number(2)),
    (.string("1"), .string("2")),
])
func malformedOrNonIncreasingRestartChangesStayNeutral(
    oldValue: CellTypedValue,
    newValue: CellTypedValue
) {
    let detector = ResourceRowChangeDetector(columnDefinitions: [
        changeDefinition(id: "restart-total", source: .builtin, value: "restarts"),
    ])
    let changes = detector.changes(
        from: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "old", typedValue: oldValue),
        ]),
        to: changeRow(uid: "pod", cells: [
            changeCell("restart-total", "new", typedValue: newValue),
        ])
    )

    #expect(changes.count == 1)
    #expect(changes.first?.emphasis == .neutral)
}

@Test(arguments: [
    changeDefinition(id: "restarts", source: .metric, value: "restarts"),
    changeDefinition(id: "restarts", source: .cel, value: "restarts"),
    changeDefinition(id: "restarts", source: .builtin, value: "pod.restarts"),
    changeDefinition(id: "restarts", source: .builtin, value: "status"),
])
func nonExactRestartDefinitionsStayNeutral(definition: ColumnDefinition) {
    let detector = ResourceRowChangeDetector(columnDefinitions: [definition])
    let changes = detector.changes(
        from: changeRow(uid: "pod", cells: [
            changeCell("restarts", "1", typedValue: .integer(1)),
        ]),
        to: changeRow(uid: "pod", cells: [
            changeCell("restarts", "2", typedValue: .integer(2)),
        ])
    )

    #expect(changes.first?.emphasis == .neutral)
}

@Test func duplicateColumnDefinitionsCannotCreateRegressionSemantics() {
    let detector = ResourceRowChangeDetector(columnDefinitions: [
        changeDefinition(id: "count", source: .builtin, value: "restarts"),
        changeDefinition(id: "count", source: .cel, value: "restarts"),
    ])
    let changes = detector.changes(
        from: changeRow(uid: "pod", cells: [
            changeCell("count", "1", typedValue: .integer(1)),
        ]),
        to: changeRow(uid: "pod", cells: [
            changeCell("count", "2", typedValue: .integer(2)),
        ])
    )

    #expect(changes.first?.emphasis == .neutral)
}

@Test func highlightStoreHoldsThenLinearlyFadesAndExpires() {
    let start = ContinuousClock.now
    let address = ResourceCellAddress(uid: "pod", columnID: "cpu")
    var store = ResourceCellHighlightStore()
    store.record([ResourceCellChange(address: address)], at: start)

    #expect(store.presentation(for: address, at: start)?.strength == 1)
    #expect(store.presentation(
        for: address,
        at: start.advanced(by: .milliseconds(150))
    )?.strength == 1)

    let halfway = store.presentation(
        for: address,
        at: start.advanced(by: .milliseconds(825))
    )
    #expect(halfway?.emphasis == .neutral)
    #expect(abs((halfway?.strength ?? 0) - 0.5) < 0.000_001)

    #expect(store.presentation(
        for: address,
        at: start.advanced(by: .milliseconds(1_499))
    ) != nil)
    #expect(store.presentation(
        for: address,
        at: start.advanced(by: .milliseconds(1_500))
    ) == nil)
    #expect(store.count == 1)

    #expect(store.expire(
        at: start.advanced(by: .milliseconds(1_500))
    ) == [address])
    #expect(store.isEmpty)
}

@Test func repeatedHighlightUpdateResetsLifetimeAndEmphasis() {
    let start = ContinuousClock.now
    let address = ResourceCellAddress(uid: "pod", columnID: "restarts")
    var store = ResourceCellHighlightStore()
    store.record([ResourceCellChange(address: address)], at: start)
    let resetAt = start.advanced(by: .seconds(1))
    store.record([
        ResourceCellChange(address: address, emphasis: .regression),
    ], at: resetAt)

    #expect(store.count == 1)
    #expect(store.presentation(
        for: address,
        at: resetAt.advanced(by: .milliseconds(149))
    ) == ResourceCellHighlightPresentation(emphasis: .regression, strength: 1))
    #expect(store.presentation(
        for: address,
        at: resetAt.advanced(by: .milliseconds(1_499))
    ) != nil)
    #expect(store.expire(
        at: resetAt.advanced(by: .milliseconds(1_500))
    ) == [address])
}

@Test func highlightStoreUsesMonotonicMutationTimestamps() {
    let start = ContinuousClock.now
    let address = ResourceCellAddress(uid: "pod", columnID: "cpu")
    var store = ResourceCellHighlightStore()
    let later = start.advanced(by: .seconds(1))
    store.record([ResourceCellChange(address: address)], at: later)

    // A delayed callback cannot move the reset timestamp backwards.
    store.record([
        ResourceCellChange(address: address, emphasis: .regression),
    ], at: start.advanced(by: .milliseconds(500)))
    #expect(store.presentation(
        for: address,
        at: later.advanced(by: .milliseconds(149))
    ) == ResourceCellHighlightPresentation(emphasis: .regression, strength: 1))
    #expect(store.expire(
        at: later.advanced(by: .milliseconds(1_499))
    ).isEmpty)
    #expect(store.expire(
        at: later.advanced(by: .milliseconds(1_500))
    ) == [address])
}

@Test func highlightStoreRemovesDeletedUIDsWithoutTouchingOthers() {
    let start = ContinuousClock.now
    let deletedA = ResourceCellAddress(uid: "deleted", columnID: "cpu")
    let deletedB = ResourceCellAddress(uid: "deleted", columnID: "memory")
    let survivor = ResourceCellAddress(uid: "survivor", columnID: "cpu")
    var store = ResourceCellHighlightStore()
    store.record([
        ResourceCellChange(address: deletedA),
        ResourceCellChange(address: survivor),
        ResourceCellChange(address: deletedB),
    ], at: start)

    #expect(store.removeAll(forUIDs: ["deleted"]) == [deletedA, deletedB])
    #expect(store.addresses == [survivor])
}

@Test func sameNameReplacementWithNewUIDInheritsNoHighlight() {
    let start = ContinuousClock.now
    let oldAddress = ResourceCellAddress(uid: "old-uid", columnID: "status")
    let replacementAddress = ResourceCellAddress(uid: "new-uid", columnID: "status")
    var store = ResourceCellHighlightStore()
    store.record([ResourceCellChange(address: oldAddress)], at: start)
    store.removeAll(forUIDs: ["old-uid"])

    #expect(store.presentation(for: oldAddress, at: start) == nil)
    #expect(store.presentation(for: replacementAddress, at: start) == nil)
}

@Test func highlightStorePrioritizesVisibleUIDsThenNewestRecords() {
    let start = ContinuousClock.now
    let hiddenOld = ResourceCellAddress(uid: "hidden-old", columnID: "status")
    let visibleOld = ResourceCellAddress(uid: "visible", columnID: "status")
    let hiddenNew = ResourceCellAddress(uid: "hidden-new", columnID: "status")
    let hiddenNewest = ResourceCellAddress(uid: "hidden-newest", columnID: "status")
    var store = ResourceCellHighlightStore(maximumRecordCount: 3)

    let affected = store.record([
        ResourceCellChange(address: hiddenOld),
        ResourceCellChange(address: visibleOld),
        ResourceCellChange(address: hiddenNew),
        ResourceCellChange(address: hiddenNewest),
    ], at: start, visibleUIDs: ["visible"])

    #expect(affected == [hiddenOld, visibleOld, hiddenNew, hiddenNewest])
    #expect(store.addresses == [visibleOld, hiddenNew, hiddenNewest])
}

@Test func highlightStoreKeepsNewestWhenVisibleRecordsExceedCapacity() {
    let start = ContinuousClock.now
    let first = ResourceCellAddress(uid: "first", columnID: "status")
    let second = ResourceCellAddress(uid: "second", columnID: "status")
    let third = ResourceCellAddress(uid: "third", columnID: "status")
    var store = ResourceCellHighlightStore(maximumRecordCount: 2)
    store.record([
        ResourceCellChange(address: first),
        ResourceCellChange(address: second),
        ResourceCellChange(address: third),
    ], at: start, visibleUIDs: ["first", "second", "third"])

    #expect(store.addresses == [second, third])
}

@Test func repeatedAddressBecomesNewForCapacityEviction() {
    let start = ContinuousClock.now
    let first = ResourceCellAddress(uid: "first", columnID: "status")
    let second = ResourceCellAddress(uid: "second", columnID: "status")
    let third = ResourceCellAddress(uid: "third", columnID: "status")
    var store = ResourceCellHighlightStore(maximumRecordCount: 2)
    store.record([
        ResourceCellChange(address: first),
        ResourceCellChange(address: second),
    ], at: start)
    store.record([
        ResourceCellChange(address: first),
        ResourceCellChange(address: third),
    ], at: start.advanced(by: .milliseconds(1)))

    #expect(store.addresses == [first, third])
}

@Test func defaultHighlightStoreNeverExceeds4096Records() {
    let start = ContinuousClock.now
    let changes = (0...ResourceCellHighlightStore.defaultMaximumRecordCount).map {
        ResourceCellChange(address: ResourceCellAddress(
            uid: ResourceUID("pod-\($0)"),
            columnID: "status"
        ))
    }
    let first = changes[0].address
    let second = changes[1].address
    var store = ResourceCellHighlightStore()
    store.record(changes, at: start, visibleUIDs: [first.uid])

    #expect(store.count == 4_096)
    #expect(store.addresses.contains(first))
    #expect(!store.addresses.contains(second))
    #expect(store.addresses.contains(changes.last!.address))
}

@Test func recordingAlsoExpiresOldRecordsAndContextClearReturnsAllAddresses() {
    let start = ContinuousClock.now
    let old = ResourceCellAddress(uid: "old", columnID: "cpu")
    let new = ResourceCellAddress(uid: "new", columnID: "cpu")
    var store = ResourceCellHighlightStore()
    store.record([ResourceCellChange(address: old)], at: start)
    let affected = store.record(
        [ResourceCellChange(address: new)],
        at: start.advanced(by: .milliseconds(1_500))
    )

    #expect(affected == [old, new])
    #expect(store.addresses == [new])
    #expect(store.removeAll() == [new])
    #expect(store.isEmpty)
}

@Test func highlightStoreProvidesOneCoalescedRefreshSchedule() {
    let start = ContinuousClock.now
    let address = ResourceCellAddress(uid: "pod", columnID: "cpu")
    var store = ResourceCellHighlightStore()
    #expect(store.nextRefreshDelay(at: start) == nil)

    store.record([ResourceCellChange(address: address)], at: start)
    #expect(store.nextRefreshDelay(at: start) == .milliseconds(150))
    #expect(store.nextRefreshDelay(
        at: start.advanced(by: .milliseconds(149))
    ) == .milliseconds(1))
    #expect(store.nextRefreshDelay(
        at: start.advanced(by: .milliseconds(150))
    ) == .milliseconds(33))
    #expect(store.nextRefreshDelay(
        at: start.advanced(by: .milliseconds(1_490))
    ) == .milliseconds(10))
    #expect(store.nextRefreshDelay(
        at: start.advanced(by: .milliseconds(1_500))
    ) == .zero)

    store.expire(at: start.advanced(by: .milliseconds(1_500)))
    #expect(store.nextRefreshDelay(
        at: start.advanced(by: .milliseconds(1_500))
    ) == nil)
}

@Test func reducedMotionCanSleepDirectlyUntilTheEarliestExpiry() {
    let start = ContinuousClock.now
    let first = ResourceCellAddress(uid: "first", columnID: "cpu")
    let second = ResourceCellAddress(uid: "second", columnID: "cpu")
    var store = ResourceCellHighlightStore()

    #expect(store.nextExpiryDelay(at: start) == nil)
    store.record([ResourceCellChange(address: first)], at: start)
    #expect(store.nextExpiryDelay(at: start) == .milliseconds(1_500))

    store.record(
        [ResourceCellChange(address: second)],
        at: start.advanced(by: .milliseconds(400))
    )
    #expect(store.nextExpiryDelay(
        at: start.advanced(by: .milliseconds(900))
    ) == .milliseconds(600))
    #expect(store.nextExpiryDelay(
        at: start.advanced(by: .milliseconds(1_500))
    ) == .zero)
}

private func changeRow(
    uid: ResourceUID,
    name: String = "object",
    cells: [Cell]
) -> ResourceRow {
    ResourceRow(
        identity: ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "default",
            name: name,
            uid: uid
        ),
        cells: cells
    )
}

private func changeCell(
    _ columnID: String,
    _ displayText: String,
    typedValue: CellTypedValue? = nil,
    severity: CellSeverity = .normal
) -> Cell {
    Cell(
        columnID: columnID,
        displayText: displayText,
        typedValue: typedValue,
        severity: severity
    )
}

private func changeDefinition(
    id: String,
    source: ColumnSource,
    value: String
) -> ColumnDefinition {
    ColumnDefinition(
        id: id,
        title: id,
        source: source,
        expression: source == .cel ? "object.metadata.name" : nil,
        value: value,
        type: .integer
    )
}
