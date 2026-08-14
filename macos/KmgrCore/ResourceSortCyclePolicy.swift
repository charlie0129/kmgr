/// Normalizes AppKit's native two-state header sort toggle into the
/// three-state cycle used by resource tables: ascending, descending, then
/// unsorted. AppKit proposes ascending again for the third click, so only that
/// exact single-column transition is translated to an empty descriptor list.
public enum ResourceSortCyclePolicy {
    public static func applyingHeaderClickCycle(
        previous: [SortDescriptorState],
        proposed: [SortDescriptorState]
    ) -> [SortDescriptorState] {
        guard previous.count == 1,
            proposed.count == 1,
            previous[0].columnID == proposed[0].columnID,
            !previous[0].ascending,
            proposed[0].ascending
        else { return proposed }
        return []
    }
}
