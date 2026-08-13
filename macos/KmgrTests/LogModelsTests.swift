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

@Test func hugeLogRecordIsFragmentedAndNewestBytesRemainBounded() {
    var ring = LogRecordRing(recordLimit: 4, byteLimit: 8, fragmentByteLimit: 3)
    ring.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("abcdefghijkl".utf8), endsWithNewline: true)
    ])
    #expect(ring.records.map { String(decoding: $0.data, as: UTF8.self) } == ["ghi", "jkl"])
    #expect(ring.records.map(\.endsWithNewline) == [false, true])
    #expect(ring.byteCount == 6)
    #expect(ring.droppedRecords == 2)
    #expect(ring.droppedBytes == 6)
}

@Test func sustainedRingEvictionPreservesStrictRecordAndByteBounds() {
    var ring = LogRecordRing(recordLimit: 128, byteLimit: 1 << 10, fragmentByteLimit: 64)
    for index in 0..<20_000 {
        ring.append(contentsOf: [LogRecord(
            sourceID: "source",
            data: Data("record-\(index)".utf8),
            endsWithNewline: true
        )])
        #expect(ring.recordCount <= 128)
        #expect(ring.byteCount <= 1 << 10)
    }
    #expect(ring.records.last.map { String(decoding: $0.data, as: UTF8.self) } == "record-19999")
    #expect(ring.droppedRecords > 0)
}

@Test func logRendererBoundsInvalidUTF8ExpansionAndKeepsNewestRecords() throws {
    let records = [
        LogRecord(sourceID: "old", data: Data("old line".utf8), endsWithNewline: true),
        LogRecord(sourceID: "new", data: Data(repeating: 0xff, count: 40), endsWithNewline: true),
        LogRecord(sourceID: "new", data: Data("newest".utf8), endsWithNewline: true),
    ]
    let rendered = try LogTextRenderer.render(
        records: records,
        sourceLabels: ["old": "old", "new": "new\nforged"],
        showSourceLabels: true,
        filter: "",
        maximumOutputUTF8Bytes: 32
    )

    #expect(rendered.outputUTF8Bytes <= 32)
    #expect(rendered.text.contains("newest"))
    #expect(!rendered.text.contains("old line"))
    #expect(!rendered.text.contains("new\nforged"))
    #expect(rendered.omittedRecords == 2)
}

@Test func logRendererFiltersDecodedRecordsAndKeepsSpacesInLabels() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(sourceID: "a", data: Data("Ready API".utf8), endsWithNewline: true),
            LogRecord(sourceID: "b", data: Data("not selected".utf8), endsWithNewline: true),
        ],
        sourceLabels: ["a": "pod a"],
        showSourceLabels: true,
        filter: "api",
        maximumOutputUTF8Bytes: 1 << 10
    )
    #expect(rendered.text == "[pod a] Ready API\n")
    #expect(rendered.renderedRecords == 1)
}

@Test func logDisplayConfigurationUsesValidatedPreferences() {
    let configuration = LogDisplayConfiguration(preferences: LogDisplayPreferences(
        recordLimit: 75_000,
        byteLimit: 32 << 20,
        renderBatchMilliseconds: 65
    ))
    #expect(configuration.recordLimit == 75_000)
    #expect(configuration.byteLimit == 32 << 20)
    #expect(configuration.renderBatchMilliseconds == 65)
}
