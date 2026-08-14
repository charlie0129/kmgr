import Testing
@testable import KmgrCore

@Test("resource header sort cycles ascending, descending, then unsorted")
func resourceHeaderSortCycle() {
    let ascending = [SortDescriptorState(columnID: "name", ascending: true)]
    let descending = [SortDescriptorState(columnID: "name", ascending: false)]

    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: [],
        proposed: ascending
    ) == ascending)
    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: ascending,
        proposed: descending
    ) == descending)
    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: descending,
        proposed: ascending
    ).isEmpty)
}

@Test("resource sort cycle does not reinterpret other descriptor changes")
func resourceHeaderSortCyclePreservesOtherChanges() {
    let previous = [SortDescriptorState(columnID: "name", ascending: false)]
    let changedColumn = [SortDescriptorState(columnID: "namespace", ascending: true)]
    let multiple = [
        SortDescriptorState(columnID: "name", ascending: true),
        SortDescriptorState(columnID: "namespace", ascending: false),
    ]

    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: previous,
        proposed: changedColumn
    ) == changedColumn)
    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: previous,
        proposed: multiple
    ) == multiple)
}
