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

@Test func defaultLogOpenPlansEveryContainerAndNamedContainerRowsStayExact() throws {
    let pod = podIdentity("api", uid: "api-uid")
    let resolution = LogSourceResolution(
        pods: [PodLogSourceInventory(identity: pod, containers: ["sidecar", "app"])],
        staticWorkloadSnapshot: false
    )

    let all = try LogOpenPlanner.plan(
        request: .allContainers(for: [pod]),
        resolution: resolution
    )
    #expect(all.sources.map(\.container) == ["app", "sidecar"])
    #expect(all.availableSources == all.sources)

    let app = try LogOpenPlanner.plan(
        request: .namedContainer("app", in: pod),
        resolution: resolution
    )
    #expect(app.sources.map(\.container) == ["app"])
    #expect(app.availableSources.map(\.container) == ["app", "sidecar"])

    #expect(!LogOpenRequest.allContainers(for: [pod]).previous)
    #expect(LogOpenRequest.allContainers(for: [pod], previous: true).previous)
    #expect(LogOpenRequest.namedContainer("app", in: pod, previous: true).previous)
}

@Test func defaultLogOpenRefusesAnOversizedAllContainerExpansion() throws {
    let pod = podIdentity("api", uid: "api-uid")
    let resolution = LogSourceResolution(
        pods: [PodLogSourceInventory(
            identity: pod,
            containers: (0...LogOpenPlanner.maximumSources).map { "container-\($0)" }
        )],
        staticWorkloadSnapshot: false
    )

    #expect(throws: ClusterManagerIssue.self) {
        try LogOpenPlanner.plan(
            request: .allContainers(for: [pod]),
            resolution: resolution
        )
    }
    #expect(try LogOpenPlanner.plan(
        request: .namedContainer("container-0", in: pod),
        resolution: resolution
    ).sources.count == 1)
}

@Test func compatibleWorkloadsIncludeUIDSafeStaticControllerFamilies() {
    let resources = [
        ("apps", "deployments"),
        ("apps", "statefulsets"),
        ("apps", "daemonsets"),
        ("apps", "replicasets"),
        ("batch", "jobs"),
        ("batch", "cronjobs"),
    ].map { group, resource in
        ResourceIdentity(
            clusterSessionID: "session", group: group, version: "v1",
            resource: resource, namespace: "team-a", name: "workload", uid: "uid"
        )
    }
    #expect(resources.allSatisfy(LogResourceCompatibility.supportsStaticPodResolution))
    #expect(LogResourceCompatibility.supportsSelection(resources))

    var unsupported = resources[0]
    unsupported.version = "v1beta1"
    #expect(LogResourceCompatibility.supportsStaticPodResolution(unsupported) == false)
    unsupported.version = "v1"
    unsupported.resource = "services"
    #expect(LogResourceCompatibility.supportsSelection([unsupported]) == false)
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

@Test func logSourcePresentationBoundsLargeToolbarSourceLists() {
    let sources = (0..<128).map { index in
        LogSource(
            identity: podIdentity("pod-\(index)", uid: "uid-\(index)"),
            container: "app",
            sourceID: "uid-\(index)/app",
            label: "team-a/\(String(repeating: "x", count: 40))/app"
        )
    }
    let visible = LogSourcePresentation.toolbarSummary(
        contextName: "production",
        sources: sources
    )
    let full = LogSourcePresentation.fullToolbarSummary(
        contextName: "production",
        sources: sources
    )

    #expect(visible.count <= LogSourcePresentation.maximumToolbarSummaryCharacters)
    #expect(visible.contains("… +"))
    #expect(full.count > visible.count)
    #expect(full.contains("team-a/" + String(repeating: "x", count: 40) + "/app"))
}

@Test func logSourcePresentationKeepsItsBoundWithLongContext() {
    let summary = LogSourcePresentation.toolbarSummary(
        contextName: String(repeating: "context-", count: 200),
        sources: [LogSource(
            identity: podIdentity("api", uid: "api-uid"),
            container: "app",
            sourceID: "api-uid/app",
            label: "team-a/api/app"
        )]
    )
    #expect(summary.count <= LogSourcePresentation.maximumToolbarSummaryCharacters)
}

@Test func singlePodMultiContainerPrefixesUseContainerNames() {
    let sources = [
        LogSource(
            identity: podIdentity("api", uid: "api-uid"), container: "app",
            sourceID: "api-uid/app", label: "team-a/api/app"
        ),
        LogSource(
            identity: podIdentity("api", uid: "api-uid"), container: "sidecar",
            sourceID: "api-uid/sidecar", label: "team-a/api/sidecar"
        ),
    ]
    #expect(LogSourcePresentation.prefixLabels(for: sources) == [
        "api-uid/app": "app", "api-uid/sidecar": "sidecar",
    ])
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
    #expect(ring.records.map(\.startsLine) == [false, false])
    #expect(ring.byteCount == 6)
    #expect(ring.droppedRecords == 2)
    #expect(ring.droppedBytes == 6)
}

@Test func multiMegabyteLogicalLineUsesBoundedDisplayAndLosslessExport() throws {
    let fragmentBytes = 64 << 10
    let payloadBytes = 8 << 20
    let displayedLineBytes = 16 << 10
    var ring = LogRecordRing(
        recordLimit: 1_024,
        byteLimit: payloadBytes + fragmentBytes,
        fragmentByteLimit: fragmentBytes
    )
    ring.append(contentsOf: [LogRecord(
        sourceID: "pod",
        data: Data(repeating: 0x78, count: payloadBytes),
        startsLine: true,
        endsWithNewline: true
    )])

    let records = ring.records
    #expect(records.count == payloadBytes / fragmentBytes)
    #expect(records.allSatisfy { $0.data.count <= fragmentBytes })
    #expect(records.first?.startsLine == true)
    #expect(records.dropFirst().allSatisfy { !$0.startsLine })

    let rendered = try LogTextRenderer.render(
        records: records,
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: payloadBytes + fragmentBytes,
        maximumDisplayedLineUTF8Bytes: displayedLineBytes
    )

    #expect(rendered.text.utf8.count == payloadBytes + 1)
    #expect(rendered.text.hasPrefix(String(repeating: "x", count: fragmentBytes)))
    #expect(rendered.displayTruncatedLines == 1)
    #expect(rendered.displayText.hasPrefix(String(
        repeating: "x",
        count: displayedLineBytes
    )))
    #expect(rendered.displayText.contains(LogTextRenderer.displayTruncationMarker))
    #expect(rendered.displayOutputUTF8Bytes
        <= displayedLineBytes + LogTextRenderer.displayTruncationMarker.utf8.count + 2)
    let physicalLines = rendered.displayText.split(
        separator: "\n",
        omittingEmptySubsequences: false
    )
    #expect(physicalLines.count == 2)
}

@Test func displayedLineLimitSpansChunksAndKeepsUnicodeWhole() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "pod", data: Data("12".utf8),
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "pod", data: Data("🐈tail".utf8),
                startsLine: false, endsWithNewline: true
            ),
            LogRecord(
                sourceID: "pod", data: Data("next".utf8),
                startsLine: true, endsWithNewline: true
            ),
        ],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10,
        maximumDisplayedLineUTF8Bytes: 6
    )

    #expect(rendered.text == "12🐈tail\nnext\n")
    #expect(rendered.displayText == "12🐈 \(LogTextRenderer.displayTruncationMarker)\nnext\n")
    #expect(rendered.displayTruncatedLines == 1)
}

@Test func retainedBufferRendererUsesItsOwnTruncationExplanation() throws {
    let marker = LogTextRenderer.retainedBufferDisplayTruncationMarker
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "engine",
                data: Data("abcdef".utf8),
                endsWithNewline: true
            )
        ],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10,
        maximumDisplayedLineUTF8Bytes: 3,
        displayTruncationMarker: marker
    )

    #expect(rendered.displayText == "abc \(marker)\n")
}

@Test func hiddenLongLineSuffixDoesNotReinstallItsBoundedDisplay() throws {
    func record(_ value: String, startsLine: Bool) -> LogRecord {
        LogRecord(
            sourceID: "pod",
            data: Data(value.utf8),
            startsLine: startsLine,
            endsWithNewline: false
        )
    }
    let previous = try LogTextRenderer.render(
        records: [record("0123456789", startsLine: true)],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10,
        maximumDisplayedLineUTF8Bytes: 4
    )
    let current = try LogTextRenderer.render(
        records: [
            record("0123456789", startsLine: true),
            record("hidden suffix", startsLine: false),
        ],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10,
        maximumDisplayedLineUTF8Bytes: 4
    )

    let plan = LogTextInstallPlanner.plan(
        previousChunks: previous.displayChunks,
        currentChunks: current.displayChunks
    )
    #expect(previous.displayText == current.displayText)
    #expect(plan.removePrefixUTF16Length == 0)
    #expect(plan.retainedChunkCount == previous.displayChunks.count)
    #expect(plan.appendedChunkCount == 0)
    #expect(current.text == "0123456789hidden suffix")
}

@Test func interleavedLineFragmentsRemainCompleteAndUnicodeSafe() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "a", data: Data("12345".utf8),
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "b", data: Data("worker".utf8),
                startsLine: true, endsWithNewline: true
            ),
            LogRecord(
                sourceID: "a", data: Data("🐈tail".utf8),
                startsLine: false, endsWithNewline: true
            ),
            LogRecord(
                sourceID: "a", data: Data("next".utf8),
                startsLine: true, endsWithNewline: true
            ),
        ],
        sourceLabels: ["a": "api", "b": "worker"],
        showSourceLabels: true,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )

    #expect(rendered.text == "[api] 12345\n"
        + "[worker] worker\n"
        + "[api] … 🐈tail\n"
        + "[api] next\n")
}

@Test func appendedLongLineSuffixInstallsWithoutReplacingItsPrefix() throws {
    func record(_ value: String, startsLine: Bool, endsWithNewline: Bool = false) -> LogRecord {
        LogRecord(
            sourceID: "pod", data: Data(value.utf8),
            startsLine: startsLine, endsWithNewline: endsWithNewline
        )
    }
    let previous = try LogTextRenderer.render(
        records: [record("0123456789", startsLine: true)],
        sourceLabels: [:], showSourceLabels: false, filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )
    let current = try LogTextRenderer.render(
        records: [
            record("0123456789", startsLine: true),
            record("hidden suffix", startsLine: false, endsWithNewline: true),
        ],
        sourceLabels: [:], showSourceLabels: false, filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )

    let plan = LogTextInstallPlanner.plan(
        previousChunks: previous.chunks,
        currentChunks: current.chunks
    )
    #expect(plan.removePrefixUTF16Length == 0)
    #expect(plan.retainedChunkCount == previous.chunks.count)
    #expect(plan.appendedChunkCount == 2)
    #expect(current.chunks.dropFirst(plan.retainedChunkCount).joined()
        == "hidden suffix\n")
    #expect(current.text == "0123456789hidden suffix\n")
}

@Test func oversizedLineEvictionRebuildsAnUnambiguousLogicalPrefix() throws {
    func record(_ value: String, startsLine: Bool, endsWithNewline: Bool = false) -> LogRecord {
        LogRecord(
            sourceID: "pod",
            data: Data(value.utf8),
            startsLine: startsLine,
            endsWithNewline: endsWithNewline
        )
    }
    let previous = try LogTextRenderer.render(
        records: [
            record("first", startsLine: true),
            record("second", startsLine: false),
            record("third", startsLine: false),
        ],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )
    let current = try LogTextRenderer.render(
        records: [
            record("second", startsLine: false),
            record("third", startsLine: false),
            record("fourth", startsLine: false, endsWithNewline: true),
        ],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )

    let plan = LogTextInstallPlanner.plan(
        previousChunks: previous.chunks,
        currentChunks: current.chunks
    )
    #expect(plan.removePrefixUTF16Length == previous.text.utf16.count)
    #expect(plan.retainedChunkCount == 0)
    #expect(current.chunks.dropFirst(plan.retainedChunkCount).joined()
        == current.text)
}

@Test func logRendererPrefixesOnlyTheStartOfAHugeLogicalLine() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "pod", data: Data("first ".utf8),
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "pod", data: Data("continued ".utf8),
                startsLine: false, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "pod", data: Data("finished".utf8),
                startsLine: false, endsWithNewline: true
            ),
        ],
        sourceLabels: ["pod": "team-a/api/app"],
        showSourceLabels: true,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )
    #expect(rendered.text == "[team-a/api/app] first continued finished\n")
}

@Test func logRendererRestoresSourceIdentityForAVisibleContinuationGap() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "pod", data: Data("filtered beginning ".utf8),
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "pod", data: Data("MATCH continuation".utf8),
                startsLine: false, endsWithNewline: true
            ),
        ],
        sourceLabels: ["pod": "team-a/api/app"],
        showSourceLabels: true,
        filter: "match",
        maximumOutputUTF8Bytes: 1 << 10
    )
    #expect(rendered.text == "[team-a/api/app] … MATCH continuation\n")
}

@Test func logRendererSeparatesInterleavedOversizedFragmentsByVisibleSource() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "a", data: Data("first fragment".utf8),
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "b", data: Data("complete line".utf8),
                startsLine: true, endsWithNewline: true
            ),
            LogRecord(
                sourceID: "a", data: Data("last fragment".utf8),
                startsLine: false, endsWithNewline: true
            ),
        ],
        sourceLabels: ["a": "team-a/api/app", "b": "team-b/worker/app"],
        showSourceLabels: true,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )
    #expect(rendered.text == "[team-a/api/app] first fragment\n"
        + "[team-b/worker/app] complete line\n"
        + "[team-a/api/app] … last fragment\n")
    #expect(rendered.outputUTF8Bytes <= 1 << 10)
}

@Test func logRendererDoesNotJoinFragmentsAcrossAFilteredInterleavedRecord() throws {
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "a", data: Data("MATCH first".utf8),
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "b", data: Data("filtered other source".utf8),
                startsLine: true, endsWithNewline: true
            ),
            LogRecord(
                sourceID: "a", data: Data("MATCH last".utf8),
                startsLine: false, endsWithNewline: true
            ),
        ],
        sourceLabels: ["a": "team-a/api/app", "b": "team-b/worker/app"],
        showSourceLabels: true,
        filter: "match",
        maximumOutputUTF8Bytes: 1 << 10
    )
    #expect(rendered.text == "[team-a/api/app] MATCH first\n"
        + "[team-a/api/app] … MATCH last\n")
}

@Test func logRendererShowsRequestedTimestampOncePerLogicalLine() throws {
    let timestamp = Int64(1_723_524_306_123)
    let rendered = try LogTextRenderer.render(
        records: [
            LogRecord(
                sourceID: "pod", data: Data("first ".utf8),
                timestampUnixMilliseconds: timestamp,
                startsLine: true, endsWithNewline: false
            ),
            LogRecord(
                sourceID: "pod", data: Data("continued".utf8),
                timestampUnixMilliseconds: timestamp,
                startsLine: false, endsWithNewline: true
            ),
        ],
        sourceLabels: [:],
        showSourceLabels: false,
        filter: "",
        maximumOutputUTF8Bytes: 1 << 10
    )
    #expect(rendered.text == "2024-08-13T04:45:06.123Z first continued\n")
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

@Test func logInstallPlanDropsOnlyEvictedPrefixAndAppendsNewSuffix() {
    let previous = ["old\n", "keep\n"]
    let current = ["keep\n", "new 🐈\n"]
    let plan = LogTextInstallPlanner.plan(
        previousChunks: previous,
        currentChunks: current
    )

    #expect(plan.removePrefixUTF16Length == "old\n".utf16.count)
    #expect(plan.retainedChunkCount == 1)
    #expect(plan.appendedChunkCount == 1)
    #expect(plan.appendedUTF8Length == "new 🐈\n".utf8.count)
    #expect(plan.resultUTF16Length == current.joined().utf16.count)
    let selection = NSRange(
        location: "old\n".utf16.count + 1,
        length: 3
    )
    #expect(plan.remapSelection(selection) == NSRange(location: 1, length: 3))
}

@Test func logInstallPlanUsesAppendOnlyForStreamingGrowth() {
    let previous = ["one\n", "two\n"]
    let current = previous + ["three\n"]
    let plan = LogTextInstallPlanner.plan(
        previousChunks: previous,
        currentChunks: current
    )

    #expect(plan.removePrefixUTF16Length == 0)
    #expect(plan.retainedChunkCount == previous.count)
    #expect(plan.appendedChunkCount == 1)
    #expect(plan.appendedUTF8Length == "three\n".utf8.count)
}

@Test func logInstallPlanFallsBackToBoundedReplaceWhenFilterChanges() {
    let previous = ["alpha\n", "beta\n"]
    let current = ["selected\n"]
    let plan = LogTextInstallPlanner.plan(
        previousChunks: previous,
        currentChunks: current
    )

    #expect(plan.removePrefixUTF16Length == previous.joined().utf16.count)
    #expect(plan.retainedChunkCount == 0)
    #expect(plan.appendedChunkCount == current.count)
    #expect(plan.appendedUTF8Length == current.joined().utf8.count)
    #expect(plan.remapSelection(NSRange(location: 2, length: 3)) == NSRange(location: 0, length: 0))
}

@Test func logDisplayConfigurationUsesValidatedPreferences() {
    let configuration = LogDisplayConfiguration(preferences: LogDisplayPreferences(
        recordLimit: 75_000,
        byteLimit: 32 << 20,
        renderBatchMilliseconds: 65,
        maximumRenderedUTF8Bytes: 20 << 20,
        maximumDisplayedLineUTF8Bytes: 12 << 10
    ))
    #expect(configuration.recordLimit == 75_000)
    #expect(configuration.byteLimit == 32 << 20)
    #expect(configuration.renderBatchMilliseconds == 65)
    #expect(configuration.maximumRenderedUTF8Bytes == 20 << 20)
    #expect(configuration.maximumDisplayedLineUTF8Bytes == 12 << 10)
}
