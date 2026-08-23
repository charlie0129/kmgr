import Foundation
@testable import KmgrIPC
import Testing

@Suite("Engine diagnostics")
struct EngineDiagnosticsTests {
    @Test("stderr chunks retain line boundaries across reads")
    func stderrChunksRetainLineBoundariesAcrossReads() async throws {
        let store = EngineDiagnosticsStore(recordLimit: 20, byteLimit: 1_024)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let generation = await store.beginGeneration(startedAt: startedAt)

        await store.append(data: Data("first".utf8))
        await store.append(data: Data(" line\nsecond\n".utf8))

        let snapshot = try #require(await store.currentSnapshot())
        #expect(snapshot.generation == generation)
        #expect(snapshot.startedAt == startedAt)
        #expect(snapshot.isCurrent)
        #expect(!snapshot.unexpected)
        #expect(snapshot.records.map { String(decoding: $0.data, as: UTF8.self) } == [
            "first",
            " line",
            "second",
        ])
        #expect(snapshot.records.map(\.startsLine) == [true, false, true])
        #expect(snapshot.records.map(\.endsWithNewline) == [false, true, true])
        #expect(snapshot.statistics.recordCount == 3)
        #expect(snapshot.statistics.byteCount == "first linesecond".utf8.count)
    }

    @Test("in-memory stderr retention stays within record and byte bounds")
    func retentionStaysWithinBounds() async throws {
        let store = EngineDiagnosticsStore(recordLimit: 2, byteLimit: 7)
        _ = await store.beginGeneration()

        await store.append(data: Data("one\n".utf8))
        await store.append(data: Data("two\n".utf8))
        await store.append(data: Data("last\n".utf8))

        let snapshot = try #require(await store.currentSnapshot())
        #expect(snapshot.records.map { String(decoding: $0.data, as: UTF8.self) } == [
            "two",
            "last",
        ])
        #expect(snapshot.statistics.recordCount <= 2)
        #expect(snapshot.statistics.byteCount <= 7)
        #expect(snapshot.statistics.droppedRecords == 1)
        #expect(snapshot.statistics.droppedBytes == 3)
    }

    @Test("unexpected generations retain metadata and take preference over current output")
    func unexpectedGenerationIsPreferred() async throws {
        let store = EngineDiagnosticsStore(recordLimit: 20, byteLimit: 1_024)
        let firstStartedAt = Date(timeIntervalSince1970: 2_000)
        let firstReadyAt = Date(timeIntervalSince1970: 2_001)
        let firstEndedAt = Date(timeIntervalSince1970: 2_003)
        let firstGeneration = await store.beginGeneration(startedAt: firstStartedAt)
        await store.markReady(instanceID: "engine-first", at: firstReadyAt)
        await store.append(data: Data("panic marker\n".utf8))
        let finished = try #require(await store.finishGeneration(
            termination: EngineTermination(status: 9, reason: .uncaughtSignal),
            unexpected: true,
            endedAt: firstEndedAt
        ))

        #expect(finished.generation == firstGeneration)
        #expect(finished.readyAt == firstReadyAt)
        #expect(finished.endedAt == firstEndedAt)
        #expect(finished.engineInstanceID == "engine-first")
        #expect(finished.termination == EngineTermination(
            status: 9,
            reason: .uncaughtSignal
        ))
        #expect(finished.readyDurationMilliseconds == 2_000)
        #expect(finished.unexpected)
        #expect(!finished.isCurrent)

        let secondGeneration = await store.beginGeneration()
        await store.append(data: Data("current generation\n".utf8))
        let current = try #require(await store.currentSnapshot())
        #expect(current.generation == secondGeneration)
        #expect(current.isCurrent)
        #expect(!current.unexpected)
        #expect(current.termination == nil)

        let preferred = try #require(await store.preferredSnapshot())
        #expect(preferred.generation == firstGeneration)
        #expect(preferred.records.map { String(decoding: $0.data, as: UTF8.self) } == [
            "panic marker",
        ])

        _ = await store.finishGeneration(
            termination: EngineTermination(status: 0, reason: .exit),
            unexpected: false
        )
        let afterNormalFinish = try #require(await store.preferredSnapshot())
        #expect(afterNormalFinish.generation == firstGeneration)
    }
}
