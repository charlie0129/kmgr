import Testing
@testable import KmgrCore

@Test func scrollAnchorFollowsSameUIDAcrossLargeMove() {
    let previous: [ResourceUID] = ["a", "b", "c", "d"]
    let reordered: [ResourceUID] = ["d", "c", "a", "b"]
    let anchor = ScrollAnchor(uid: "b", pixelOffsetFromTop: 11, priorRowIndex: 1)

    let plan = ScrollRestorationPlanner.plan(
        anchor: anchor,
        previousOrder: previous,
        newOrder: reordered
    )

    #expect(plan == ScrollRestorationPlan(
        uid: "b",
        rowIndex: 3,
        pixelOffsetFromTop: 11,
        precision: .exactIdentity
    ))
}

@Test func deletedScrollAnchorUsesNearestSurvivingIdentity() {
    let previous: [ResourceUID] = ["a", "b", "c", "d"]
    let newOrder: [ResourceUID] = ["d", "a", "c"]
    let anchor = ScrollAnchor(uid: "b", pixelOffsetFromTop: 4, priorRowIndex: 1)

    let plan = ScrollRestorationPlanner.plan(
        anchor: anchor,
        previousOrder: previous,
        newOrder: newOrder
    )

    // The next old neighbor (`c`) is preferred even though it moved.
    #expect(plan == ScrollRestorationPlan(
        uid: "c",
        rowIndex: 2,
        pixelOffsetFromTop: 4,
        precision: .nearestSurvivingIdentity
    ))
}

@Test func scrollRestorationReturnsNilForEmptyProjection() {
    let plan = ScrollRestorationPlanner.plan(
        anchor: ScrollAnchor(uid: "a", pixelOffsetFromTop: 0, priorRowIndex: 0),
        previousOrder: ["a"],
        newOrder: []
    )
    #expect(plan == nil)
}
