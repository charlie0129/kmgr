import Foundation
import Testing
@testable import KmgrCore

@Test func logRingEvictsOldestByRecordAndByteLimits() {
    var ring = LogRecordRing(recordLimit: 2, byteLimit: 7)
    ring.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("abc".utf8), endsWithNewline: false),
        LogRecord(sourceID: "a", data: Data("de".utf8), endsWithNewline: false),
        LogRecord(sourceID: "b", data: Data("fghi".utf8), endsWithNewline: true),
    ])
    #expect(ring.records.map(\.data) == [Data("de".utf8), Data("fghi".utf8)])
    #expect(ring.byteCount == 6)
    #expect(ring.droppedRecords == 1)
    #expect(ring.droppedBytes == 3)
}

@Test func oversizedLogRecordIsDroppedWithoutGrowingRing() {
    var ring = LogRecordRing(recordLimit: 4, byteLimit: 3)
    ring.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("huge".utf8), endsWithNewline: false)
    ])
    #expect(ring.records.isEmpty)
    #expect(ring.byteCount == 0)
    #expect(ring.droppedRecords == 1)
    #expect(ring.droppedBytes == 4)
}
