import Foundation
import Testing
@testable import KmgrCore

@Suite("Resource list presentation policy")
struct ResourceListPresentationTests {
    @Test("small tables measure every row")
    func smallAutoWidthSample() {
        let policy = TableColumnAutoWidthPolicy(maximumSampleCount: 8)

        #expect(policy.sampleIndexes(rowCount: 5, visibleRows: 2..<4)
            == IndexSet(integersIn: 0..<5))
        #expect(policy.sampleIndexes(rowCount: 0).isEmpty)
    }

    @Test("large table sampling is bounded and retains visible rows")
    func boundedAutoWidthSample() {
        let policy = TableColumnAutoWidthPolicy(maximumSampleCount: 8)

        let sample = policy.sampleIndexes(rowCount: 100_000, visibleRows: 40..<43)

        #expect(sample.count == 8)
        #expect(sample.contains(integersIn: 40..<43))
        #expect(sample.contains(0))
        #expect(sample.max() == 99_999)
    }

    @Test("oversized visible ranges remain within the sample budget")
    func oversizedVisibleRangeIsSampled() {
        let policy = TableColumnAutoWidthPolicy(maximumSampleCount: 4)

        let sample = policy.sampleIndexes(rowCount: 1_000, visibleRows: 100..<200)

        #expect(sample.count == 4)
        #expect(sample.min() == 100)
        #expect(sample.max() == 199)
        #expect(sample.allSatisfy { (100..<200).contains($0) })
    }

    @Test("auto width rounds and obeys column and global bounds")
    func autoWidthClamping() {
        let policy = TableColumnAutoWidthPolicy(maximumWidth: 640)

        #expect(policy.fittedWidth(
            candidateWidth: 120.1,
            minimumWidth: 80,
            columnMaximumWidth: 900
        ) == 121)
        #expect(policy.fittedWidth(
            candidateWidth: 20,
            minimumWidth: 80,
            columnMaximumWidth: 900
        ) == 80)
        #expect(policy.fittedWidth(
            candidateWidth: 800,
            minimumWidth: 80,
            columnMaximumWidth: 900
        ) == 640)
        #expect(policy.fittedWidth(
            candidateWidth: 500,
            minimumWidth: 80,
            columnMaximumWidth: 320
        ) == 320)
    }

    @Test("hidden issue state anchors the table directly below the header")
    func inlineIssueRowState() {
        var state = ResourceListInlineIssueState()

        #expect(state.isHidden)
        #expect(state.message == nil)
        #expect(state.tableTopAnchor == .header)

        state.show("The stream disconnected.")
        #expect(!state.isHidden)
        #expect(state.message == "The stream disconnected.")
        #expect(state.tableTopAnchor == .issueRow)

        state.hide()
        #expect(state.isHidden)
        #expect(state.message == nil)
        #expect(state.tableTopAnchor == .header)
    }
}
