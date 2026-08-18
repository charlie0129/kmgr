/// Normalizes AppKit's header sorting into one primary descriptor with the
/// three-state cycle used by resource tables: ascending, descending, then
/// unsorted. AppKit retains older columns as secondary descriptors and wraps
/// the primary descriptor to ascending on its third click.
public enum ResourceSortCyclePolicy {
    public static func applyingHeaderClickCycle(
        previous: [SortDescriptorState],
        proposed: [SortDescriptorState]
    ) -> [SortDescriptorState] {
        guard let primary = proposed.first else { return [] }
        if let previousPrimary = previous.first,
            previousPrimary.columnID == primary.columnID,
            !previousPrimary.ascending,
            primary.ascending
        {
            return []
        }
        return [primary]
    }
}
