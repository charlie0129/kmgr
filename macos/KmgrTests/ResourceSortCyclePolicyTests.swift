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

@Test("resource sort cycle drops AppKit's retained secondary columns")
func resourceHeaderSortCycleKeepsOnlyPrimaryColumn() {
    let name = SortDescriptorState(columnID: "name", ascending: true)
    let namespace = SortDescriptorState(columnID: "namespace", ascending: true)
    let proposed = [
        namespace,
        name,
    ]

    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: [name],
        proposed: proposed
    ) == [namespace])
    #expect(ResourceSortCyclePolicy.applyingHeaderClickCycle(
        previous: [SortDescriptorState(columnID: "namespace", ascending: false), name],
        proposed: proposed
    ).isEmpty)
}
