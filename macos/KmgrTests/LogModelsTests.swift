import Foundation
import Testing
@testable import KmgrCore

private func podIdentity(_ name: String, uid: String) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "",
        version: "v1",
        resource: "pods",
        namespace: "team-a",
        name: name,
        uid: ResourceUID(uid)
    )
}

@Test func multiPodLogsOfferAllContainersWithoutACommonName() {
    let inventories = [
        PodLogSourceInventory(
            identity: podIdentity("api", uid: "api-uid"),
            containers: ["app", "sidecar"]
        ),
        PodLogSourceInventory(
            identity: podIdentity("worker", uid: "worker-uid"),
            containers: ["worker"]
        ),
    ]

    #expect(PodLogSourcePlanner.selections(for: inventories) == [.all])
    let sources = PodLogSourcePlanner.sources(for: inventories, selection: .all)
    #expect(sources.map(\.label) == [
        "team-a/api/app", "team-a/api/sidecar", "team-a/worker/worker",
    ])
    #expect(sources.map(\.sourceID) == [
        "api-uid/app", "api-uid/sidecar", "worker-uid/worker",
    ])
}

@Test func multiPodLogsKeepCommonContainerAsNarrowerChoice() {
    let inventories = [
        PodLogSourceInventory(
            identity: podIdentity("api", uid: "api-uid"),
            containers: ["app", "proxy"]
        ),
        PodLogSourceInventory(
            identity: podIdentity("worker", uid: "worker-uid"),
            containers: ["app", "metrics"]
        ),
    ]

    #expect(PodLogSourcePlanner.selections(for: inventories) == [.all, .named("app")])
    #expect(PodLogSourcePlanner.sources(
        for: inventories,
        selection: .named("app")
    ).map(\.label) == ["team-a/api/app", "team-a/worker/app"])
}

@Test func logSourcePresentationKeepsExactContextAndSourcesVisible() {
    let source = LogSource(
        identity: podIdentity("api", uid: "api-uid"),
        container: "app",
        sourceID: "api-uid/app",
        label: "team-a/api/app"
    )
    #expect(LogSourcePresentation.toolbarSummary(
        contextName: "production",
        sources: [source]
    ) == "Context: production · Sources: team-a/api/app")
    #expect(LogSourcePresentation.titleSummary(for: [source]) == "team-a/api/app")
}

@Test func logStreamGateKeepsLatePreviousGenerationOutOfBufferAfterOptionsReset() {
    let old = LogRecord(sourceID: "pod", data: Data("old".utf8), endsWithNewline: true)
    let stale = LogRecord(sourceID: "pod", data: Data("stale".utf8), endsWithNewline: true)
    let current = LogRecord(sourceID: "pod", data: Data("current".utf8), endsWithNewline: true)
    var gate = LogStreamGenerationGate()
    var buffer = LogRecordRing(recordLimit: 10, byteLimit: 100)
    gate.begin(generation: 1)
    let oldDisposition = gate.accept(StreamCursor(generation: 1, sequence: 1))
    #expect(oldDisposition == .acceptedNewGeneration)
    if isAccepted(oldDisposition) { buffer.append(contentsOf: [old]) }

    // An options change replaces the stream before cancellation can guarantee
    // that every already-enqueued callback has drained.
    gate.begin(generation: 2)
    let staleDisposition = gate.accept(StreamCursor(generation: 1, sequence: 2))
    #expect(staleDisposition == .ignoredStaleGeneration)
    if isAccepted(staleDisposition) { buffer.append(contentsOf: [stale]) }

    let currentDisposition = gate.accept(StreamCursor(generation: 2, sequence: 1))
    #expect(currentDisposition == .acceptedNewGeneration)
    if isAccepted(currentDisposition) { buffer.append(contentsOf: [current]) }
    #expect(buffer.records.map { String(decoding: $0.data, as: UTF8.self) } == ["old", "current"])
}

@Test func logStreamGatePreservesMonotonicityWithinRequestedGeneration() {
    var gate = LogStreamGenerationGate()
    gate.begin(generation: 4)

    #expect(gate.accept(StreamCursor(generation: 4, sequence: 1)) == .acceptedNewGeneration)
    #expect(gate.accept(
        StreamCursor(generation: 4, sequence: 1)
    ) == .ignoredStaleOrDuplicateSequence)
    #expect(gate.accept(
        StreamCursor(generation: 4, sequence: 0)
    ) == .ignoredStaleOrDuplicateSequence)
    #expect(gate.accept(StreamCursor(generation: 4, sequence: 2)) == .acceptedNextSequence)
}

private func isAccepted(_ disposition: StreamMessageDisposition) -> Bool {
    disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence
}

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

@Test func resizingLogRingKeepsNewestDataAndCumulativeDropCounts() {
    var ring = LogRecordRing(recordLimit: 3, byteLimit: 100)
    ring.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("z".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("aa".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("bbb".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("cccc".utf8), endsWithNewline: true),
    ])
    #expect(ring.droppedRecords == 1)
    #expect(ring.droppedBytes == 1)

    ring.resize(recordLimit: 2, byteLimit: 6)
    #expect(ring.records.map { String(decoding: $0.data, as: UTF8.self) } == ["cccc"])
    #expect(ring.recordCount == 1)
    #expect(ring.byteCount == 4)
    #expect(ring.droppedRecords == 3)
    #expect(ring.droppedBytes == 6)

    ring.resize(recordLimit: 10, byteLimit: 100)
    #expect(ring.records.map { String(decoding: $0.data, as: UTF8.self) } == ["cccc"])
    #expect(ring.droppedRecords == 3)
    #expect(ring.droppedBytes == 6)
}

@Test func logRecordStoreCanResizeAnOpenBuffer() async {
    let store = LogRecordStore(recordLimit: 4, byteLimit: 100)
    _ = await store.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("old".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("middle".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("new".utf8), endsWithNewline: true),
    ])

    let statistics = await store.resize(recordLimit: 2, byteLimit: 10)
    let snapshot = await store.snapshot()
    #expect(snapshot.records.map { String(decoding: $0.data, as: UTF8.self) } == ["middle", "new"])
    #expect(statistics == snapshot.statistics)
    #expect(statistics.recordCount == 2)
    #expect(statistics.byteCount == 9)
    #expect(statistics.droppedRecords == 1)
}

@Test func logRecordStoreIgnoresDelayedStaleConfigurationRevision() async {
    let store = LogRecordStore(recordLimit: 10, byteLimit: 100)
    _ = await store.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("one".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("two".utf8), endsWithNewline: true),
        LogRecord(sourceID: "a", data: Data("three".utf8), endsWithNewline: true),
    ])

    _ = await store.resize(recordLimit: 2, byteLimit: 100, revision: 2)
    _ = await store.resize(recordLimit: 10, byteLimit: 100, revision: 1)
    _ = await store.append(contentsOf: [
        LogRecord(sourceID: "a", data: Data("four".utf8), endsWithNewline: true),
    ])

    let snapshot = await store.snapshot()
    #expect(snapshot.records.map { String(decoding: $0.data, as: UTF8.self) } == ["three", "four"])
    #expect(snapshot.statistics.recordCount == 2)
    #expect(snapshot.statistics.droppedRecords == 2)
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
